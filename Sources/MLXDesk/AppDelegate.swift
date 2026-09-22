import AppKit

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
    // open (.terminateLater) until any in-flight generation has actually finished avoids
    // it; a short timeout keeps Quit from hanging if generation is somehow stuck.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate, let model, model.isGenerating else { return .terminateNow }
        isPreparingToTerminate = true
        Task { @MainActor in
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
