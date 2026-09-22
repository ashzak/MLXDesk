import SwiftUI
import AppKit

@main
struct MLXDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        MetricsCollector.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    appDelegate.model = model
                    if model.runtime == .checking { await model.checkRuntime() }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                    Task { await model.systemWillSleep() }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    Task { await model.systemDidWake() }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { model.conversations.createConversation() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Model") {
                Button("Start Selected Model") { model.beginModelStart() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Show Model Inspector") { model.inspectorPresented.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        Settings { SettingsView(model: model).frame(width: 520, height: 440) }
    }
}
