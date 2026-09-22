import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ModelInspector: View {
    @Bindable var model: AppModel
    @State private var advanced = false

    var body: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $model.selectedModel) {
                    ForEach(quickModels) { item in Text(item.displayName).tag(item) }
                }
                .labelsHidden().accessibilityLabel("Selected model").accessibilityIdentifier("model.picker")
                .onChange(of: model.selectedModel) { _, _ in model.modelChanged() }
                Button { model.catalogPresented = true } label: {
                    Label("Browse All Compatible MLX Models", systemImage: "square.grid.2x2").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("catalog.open")
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(model.selectedModel.detail).fontWeight(.medium); if model.selectedModel.recommended { Text("Recommended").font(.caption2).padding(4).background(.green.opacity(0.15), in: Capsule()) } }
                    Label(model.selectedModel.bestFor, systemImage: model.selectedModel.bestForIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.selectedModel.trustLevel.isTrusted {
                        Label("Community model: compatibility is not verified", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    // The first thing to know about a newly picked model: is it already on
                    // disk, or will starting it kick off a download? `model.runtime` always
                    // describes what's happening to `model.selectedModel` -- switching models
                    // mid-download stops it (see AppModel.modelChanged) -- so branching on it
                    // here shows live download/load progress for exactly this model, not a
                    // stale readout from whatever was previously selected.
                    switch model.runtime {
                    case .downloading(let percent):
                        LinearProgressRow(label: "Downloading · \(model.selectedModel.size)", percent: percent >= 0 ? percent : nil, accessibilityID: "model.downloadProgress")
                    case .starting:
                        LinearProgressRow(label: model.runtimePhase.label, percent: model.runtimePhase.stepProgress.map { Int($0 * 100) }, accessibilityID: "model.loadProgress")
                    default:
                        if model.selectedModelDownloaded {
                            Label("Downloaded — ready to load", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                        } else {
                            Label("Not downloaded — \(model.selectedModel.size) needed", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Label("About \(model.selectedModel.memory) while running", systemImage: "memorychip").font(.caption).foregroundStyle(.secondary)
                    if let revision = model.selectedModelRevision, !revision.isEmpty {
                        Label("Revision \(String(revision.prefix(12)))", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                    if let quarantineReason = model.quarantineReason {
                        Label("Paused after repeated compatibility failures", systemImage: "shield.slash.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Text(quarantineReason).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                        Button("Clear Quarantine") { Task { await model.clearSelectedModelQuarantine() } }
                            .accessibilityIdentifier("model.clearQuarantine")
                    }
                }
                Button {
                    if model.runtime == .starting || isDownloading { model.cancelModelLoad() }
                    else { model.beginModelStart() }
                } label: {
                    if isDownloading { Label("Pause Download", systemImage: "pause.circle").frame(maxWidth: .infinity) }
                    else if model.runtime == .starting { Label("Cancel Loading", systemImage: "xmark.circle").frame(maxWidth: .infinity) }
                    else { Label(model.runtime == .running ? "Restart Model" : "Load & Start", systemImage: "play.fill").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent).disabled(model.runtime == .unavailable || model.quarantineReason != nil)
                .accessibilityIdentifier("model.start")
            }
            Section("Response") {
                LabeledContent("Creativity") {
                    Slider(value: $model.settings.temperature, in: 0...1, step: 0.1).frame(width: 120).accessibilityIdentifier("settings.temperature")
                    Text(model.settings.temperature, format: .number.precision(.fractionLength(1))).monospacedDigit().frame(width: 28)
                }
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    Stepper("Maximum tokens: \(model.settings.maxTokens)", value: $model.settings.maxTokens, in: 256...8192, step: 256)
                        .accessibilityIdentifier("settings.maxTokens")
                    Picker("Context", selection: $model.settings.contextLength) {
                        Text("8K").tag(8192); Text("16K").tag(16384); Text("32K").tag(32768); Text("64K").tag(65536)
                    }.accessibilityIdentifier("settings.context")
                }
            }
            Section("Privacy") {
                Label("Prompts stay on this Mac", systemImage: "lock.shield.fill").foregroundStyle(.secondary)
                Text("Inference runs locally with native MLX. Model downloads come from Hugging Face.").font(.caption).foregroundStyle(.tertiary)
            }
            Section("Diagnostics") {
                LabeledContent("Runtime") { Text(model.runtimePhase.label).foregroundStyle(.secondary) }
                if !model.runtimeDetail.isEmpty { Text(model.runtimeDetail).font(.caption).foregroundStyle(.secondary) }
                Button { model.diagnosticsPresented = true } label: {
                    Label("Open Diagnostics", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("diagnostics.open")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $model.diagnosticsPresented) { RuntimeDiagnosticsView(model: model) }
    }

    private var isDownloading: Bool { if case .downloading = model.runtime { true } else { false } }
    private var quickModels: [MLXModel] { [model.selectedModel] + MLXModel.curated.filter { $0.id != model.selectedModel.id } }
}

struct RuntimeDiagnosticsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var exportResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Current State") {
                    LabeledContent("Runtime", value: model.runtime.label)
                    LabeledContent("Phase", value: model.runtimePhase.label)
                    LabeledContent("Model", value: model.selectedModel.displayName)
                    if let revision = model.selectedModelRevision { LabeledContent("Revision", value: String(revision.prefix(12))) }
                    if let engineVersion = model.catalogEngineVersion {
                        LabeledContent("Hardware compatibility engine", value: "llmfit \(engineVersion)")
                    }
                    if let health = model.lastHealth {
                        HealthRow(title: "Endpoint", passed: health.endpointResponding)
                        HealthRow(title: "Generation readiness", passed: health.generationReady)
                        Text("Checked \(health.checkedAt, style: .relative)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let preflight = model.lastPreflight {
                    Section("Last Preflight") {
                        HealthRow(title: "Disk capacity", passed: preflight.isDiskSafe)
                        LabeledContent("Free disk", value: bytes(preflight.availableDiskBytes))
                        LabeledContent("Required for download", value: bytes(preflight.requiredDiskBytes))
                        LabeledContent("Physical memory", value: bytes(Int64(preflight.physicalMemoryBytes)))
                        ForEach(preflight.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }
                if let started = model.loadStartedAt {
                    Section("Last Load") {
                        if let completed = model.loadCompletedBytes { LabeledContent("Transferred", value: bytes(completed)) }
                        if let total = model.loadTotalBytes { LabeledContent("Expected", value: bytes(total)) }
                        LabeledContent("Started", value: started.formatted(date: .omitted, time: .standard))
                    }
                }
                Section("Support") {
                    Button { runCheck() } label: {
                        if checking { ProgressView().controlSize(.small) } else { Label("Run Readiness Check", systemImage: "waveform.path.ecg") }
                    }
                    .disabled(checking || model.isGenerating)
                    .accessibilityIdentifier("diagnostics.healthCheck")
                    Button { exportBundle() } label: { Label("Export Support Bundle", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("diagnostics.export")
                    Button { exportCompatibility() } label: { Label("Export Compatibility Report", systemImage: "checkmark.shield") }
                        .accessibilityIdentifier("diagnostics.exportCompatibility")
                    Text("Support bundles exclude prompts and responses.").font(.caption).foregroundStyle(.secondary)
                    if let exportResult { Text(exportResult).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.diagnosticsTitle)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private func runCheck() {
        checking = true
        Task { await model.refreshHealth(includeReadiness: model.runtime == .running); checking = false }
    }

    private func exportBundle() {
        Task {
            do {
                let data = try await model.supportBundleData()
                let panel = NSSavePanel(); panel.title = "Export MLX Desk Support Bundle"
                panel.nameFieldStringValue = "MLXDesk-Support-\(Date.now.formatted(.iso8601.year().month().day())).json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                exportResult = "Support bundle saved."
            } catch { exportResult = error.localizedDescription }
        }
    }

    private func exportCompatibility() {
        Task {
            do {
                await model.loadStorage()
                let data = try await model.compatibilityReportData()
                let panel = NSSavePanel(); panel.title = "Export MLX Compatibility Report"
                panel.nameFieldStringValue = "MLXDesk-Compatibility.json"; panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic); exportResult = "Compatibility report saved."
            } catch { exportResult = error.localizedDescription }
        }
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

struct HealthRow: View {
    let title: String
    let passed: Bool
    var body: some View {
        LabeledContent(title) { Label(passed ? "Passed" : "Failed", systemImage: passed ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(passed ? .green : .red) }
    }
}

struct SetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 48)).foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Set up private AI on your Mac").font(.title2).fontWeight(.bold)
                Text("MLX-LM is the local engine that runs compatible models. MLX Desk can install it for you using uv.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: 12) {
                SetupRow(icon: "checkmark.circle.fill", title: "Apple Silicon detected", detail: "Optimized for unified memory", color: .green)
                SetupRow(icon: "arrow.down.circle.fill", title: "Install MLX-LM", detail: "A small Python tool; models are downloaded separately", color: .accentColor)
                SetupRow(icon: "lock.shield.fill", title: "Local by default", detail: "Your conversations and prompts stay on this Mac", color: .purple)
            }.padding().background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            HStack {
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { Task { await model.installRuntime() } } label: {
                    if model.runtime == .starting { ProgressView().controlSize(.small).frame(width: 110) }
                    else { Text("Install MLX-LM").frame(width: 110) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.runtime == .starting)
                    .accessibilityIdentifier("setup.install")
            }
        }.padding(32).frame(width: 540).accessibilityIdentifier("setup.sheet")
    }
}

struct SetupRow: View {
    let icon: String, title: String, detail: String; let color: Color
    var body: some View { HStack(spacing: 12) { Image(systemName: icon).foregroundStyle(color).font(.title3); VStack(alignment: .leading) { Text(title).fontWeight(.semibold); Text(detail).font(.caption).foregroundStyle(.secondary) } } }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("System Prompt") {
                TextEditor(text: $model.settings.systemPrompt).font(.body).frame(minHeight: 130).accessibilityIdentifier("settings.systemPrompt")
                Text("Applied at the beginning of each conversation.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Conversation") {
                Button("Clear Current Conversation", role: .destructive) { if let id = model.conversations.selection { model.conversations.clearMessages(in: id) } }
                    .accessibilityIdentifier("settings.clearConversation")
            }
            Section("Model Lifecycle") {
                Picker("Unload when idle", selection: $model.preferences.idleUnloadMinutes) {
                    Text("Never").tag(0); Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("60 minutes").tag(60)
                }.onChange(of: model.preferences.idleUnloadMinutes) { _, _ in model.preferencesChanged() }
                Toggle("Unload in Low Power Mode", isOn: $model.preferences.unloadOnLowPower)
                Toggle("Protect against thermal pressure", isOn: $model.preferences.protectThermals)
                LabeledContent("Current power state", value: model.powerStatus)
            }
            Section("Models and Performance") {
                Button("Manage Downloaded Models…") { model.storagePresented = true }.accessibilityIdentifier("settings.modelStorage")
                Button("View Performance History…") { model.performancePresented = true }.accessibilityIdentifier("settings.performance")
                Button("Show Welcome Guide Again") { OnboardingState.isComplete = false; model.onboardingPresented = true }
            }
            Section("Updates") {
                Picker("Release channel", selection: $model.preferences.updateChannel) { Text("Stable").tag("Stable"); Text("Preview").tag("Preview") }
                Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }.disabled(!UpdateController.shared.isConfigured)
                Text(UpdateController.shared.isConfigured ? "Signed automatic updates are configured." : "Update checking will activate when a signed feed URL and public key are added to the release build.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).navigationTitle("MLX Desk Settings")
        .sheet(isPresented: $model.storagePresented) { ModelStorageView(model: model) }
        .sheet(isPresented: $model.performancePresented) { PerformanceHistoryView(model: model) }
        .sheet(isPresented: $model.onboardingPresented) { OnboardingView(model: model) }
    }
}
