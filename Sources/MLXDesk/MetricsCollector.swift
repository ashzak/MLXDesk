import Foundation
import MetricKit

/// Keeps Apple-provided crash and hang diagnostics on the user's Mac. Nothing is uploaded.
final class MetricsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricsCollector()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        persist(payloads.map { $0.jsonRepresentation() }, prefix: "metrics")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        persist(payloads.map { $0.jsonRepresentation() }, prefix: "diagnostics")
    }

    private func persist(_ payloads: [Data], prefix: String) {
        guard !payloads.isEmpty else { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MLXDesk/Diagnostics", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for payload in payloads {
            let name = "\(prefix)-\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString).json"
            try? payload.write(to: directory.appending(path: name), options: .atomic)
        }
    }
}
