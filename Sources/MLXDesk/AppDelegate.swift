import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isPreparingToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier, identifier != "org.swift.swiftpm" else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != currentPID }) {
            existing.activate(options: [.activateAllWindows])
            NSApplication.shared.terminate(nil)
        }
    }

    // Quitting while a response is still streaming races AppKit's termination sequence
    // against MLX's own in-flight background work, and crashes the process -- see the
    // comment on AppModel.prepareForTermination() for the full story. Holding termination
    // open (.terminateLater) gives any in-flight generation a bounded window to wind down
    // and its latest text to get persisted before we proceed; the real fix against the
    // crash itself is applicationWillTerminate below.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate, let model, model.isGenerating else { return .terminateNow }
        isPreparingToTerminate = true
        Task { @MainActor in
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // The actual fix. This fires as AppKit's very last step before the process's normal
    // exit() call -- by which point AppKit has already finished its own graceful teardown
    // (closing windows, flushing state restoration), so nothing user-visible is skipped by
    // hooking here. MLX keeps background GPU/completion-handler threads alive independent
    // of any Swift Task, tied to global C++ singletons (the Metal Device, its compiled-
    // kernel CompilerCache, ...). The normal exit() path runs those globals' static
    // destructors, which races any straggling background thread still touching them --
    // reproduced live as two different crash signatures during/just after Quit while a
    // generation was in flight: a mutex lock on an already-destroyed device, and (even
    // after AppModel.prepareForTermination() started cancelling and waiting for
    // generation) a segfault inside CompilerCache when that wait's timeout won the race.
    // `_exit` terminates every thread in the process atomically at the kernel level with
    // no destructors run at all -- ours or MLX's -- which closes the race by construction
    // rather than by hoping cancellation propagated in time. The OS reclaims all of the
    // process's memory and GPU resources regardless of how the process ends.
    func applicationWillTerminate(_ notification: Notification) {
        _exit(0)
    }
}
