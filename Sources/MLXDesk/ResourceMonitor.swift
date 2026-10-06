import Foundation
import Darwin

/// One sample of live resource usage, taken once a second by `ResourceMonitor`.
///
/// There is no public, unprivileged per-process GPU-utilization API on Apple Silicon
/// (the real number lives behind `powermetrics`, which needs sudo) -- but there also
/// isn't a separate GPU to report: on Apple Silicon the GPU reads directly out of the
/// same unified memory pool as the CPU, so this app's own resident memory IS the
/// model's footprint, GPU included, while a model is loaded. `appMemoryBytes` is
/// reported as that unified figure rather than inventing a CPU/GPU split this
/// hardware doesn't have.
struct ResourceSample: Equatable, Sendable {
    var cpuPercent: Double
    var systemMemoryUsedBytes: UInt64
    var systemMemoryTotalBytes: UInt64
    var appMemoryBytes: UInt64
    var thermalState: ProcessInfo.ThermalState

    static let zero = ResourceSample(cpuPercent: 0, systemMemoryUsedBytes: 0, systemMemoryTotalBytes: ProcessInfo.processInfo.physicalMemory, appMemoryBytes: 0, thermalState: .nominal)
}

/// Polls Mach host/task APIs once a second for a live CPU + unified-memory readout,
/// surfaced in ModelInspector's "Live Resource Usage" section. Every call here is a
/// standard, unprivileged Mach trap (`host_statistics`, `host_statistics64`,
/// `task_info`) -- no shelling out to `top`/`powermetrics`, no extra entitlements.
@MainActor @Observable
final class ResourceMonitor {
    private(set) var sample: ResourceSample = .zero
    private var pollTask: Task<Void, Never>?
    private var previousCPUTicks: host_cpu_load_info?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample = self.takeSample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    private func takeSample() -> ResourceSample {
        ResourceSample(
            cpuPercent: currentCPUPercent(),
            systemMemoryUsedBytes: systemMemoryUsed(),
            systemMemoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            appMemoryBytes: appResidentMemory(),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    /// System-wide CPU utilization, derived from the delta between two consecutive
    /// `HOST_CPU_LOAD_INFO` tick counts (the only way this call ever makes sense --
    /// a single snapshot is a cumulative counter since boot, not a percentage).
    private func currentCPUPercent() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &size)
            }
        }
        guard result == KERN_SUCCESS else { return sample.cpuPercent }
        defer { previousCPUTicks = info }
        guard let previous = previousCPUTicks else { return sample.cpuPercent }
        let userDelta = Double(info.cpu_ticks.0 &- previous.cpu_ticks.0)
        let systemDelta = Double(info.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idleDelta = Double(info.cpu_ticks.2 &- previous.cpu_ticks.2)
        let niceDelta = Double(info.cpu_ticks.3 &- previous.cpu_ticks.3)
        let busy = userDelta + systemDelta + niceDelta
        let total = busy + idleDelta
        guard total > 0 else { return 0 }
        return min(100, max(0, busy / total * 100))
    }

    /// `host_statistics64`'s VM counters, converted to bytes. "Used" here is
    /// active + wired + compressed, the same definition Activity Monitor's memory
    /// pressure gauge uses -- free + inactive/purgeable pages don't represent real
    /// pressure, so counting them as "used" would read as alarmingly high at idle.
    private func systemMemoryUsed() -> UInt64 {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var info = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // `getpagesize()` rather than the global `vm_kernel_page_size`/`vm_page_size`
        // -- same value, but a function call has no shared-mutable-state concurrency
        // warning under Swift 6's strict checking.
        let pageSize = UInt64(getpagesize())
        let active = UInt64(info.active_count) * pageSize
        let wired = UInt64(info.wire_count) * pageSize
        let compressed = UInt64(info.compressor_page_count) * pageSize
        return active + wired + compressed
    }

    /// This process's resident footprint via `TASK_VM_INFO`, which (unlike the older
    /// `MACH_TASK_BASIC_INFO`) reflects memory mapped via `mmap`/`vm_allocate` --
    /// exactly how mlx-swift's Metal buffers for model weights land in this
    /// process's address space, so this is the only accounting that actually moves
    /// when a model loads or unloads.
    private func appResidentMemory() -> UInt64 {
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = task_vm_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}
