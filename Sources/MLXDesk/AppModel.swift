import Foundation
import Observation
import Dispatch
import AppKit

@MainActor @Observable
final class AppModel {
    let conversations: ConversationStore
    var preferences: AppPreferences
    let localModelStore: LocalModelStore
    let resourceMonitor = ResourceMonitor()
    private let service: MLXService
    private let catalogService = ModelCatalogService()
    private let compatibilityStore: ModelCompatibilityStore
    private let performanceStore: PerformanceStore
    var selectedModel = MLXModel.curated[0]
    var localModelImportError: String?
    var settings = GenerationSettings()
    var runtime: RuntimeState = .checking
    var runtimePhase: RuntimePhase = .idle
    var runtimeDetail = ""
    var lastPreflight: PreflightReport?
    var lastHealth: RuntimeHealth?
    var draft = ""
    var pendingAttachments: [ComposerAttachment] = []
    var isGenerating = false
    var inspectorPresented = true
    var setupPresented = false
    var errorMessage: String?
    var tokensPerSecond: Double?
    var timeToFirstToken: Double?
    var selectedModelDownloaded = false
    var catalogModels: [MLXModel] = []
    var catalogLoading = false
    var catalogPresented = false
    var catalogError: String?
    var diagnosticsPresented = false
    var catalogHardware: FitSystem?
    var catalogUpdatedAt: Date?
    var catalogEngineVersion: String?
    var updatingModelDatabase = false
    var modelDatabaseUpdateResult: String?
    var storagePresented = false
    var performancePresented = false
    var onboardingPresented = false
    var cachedModels: [CachedModelEntry] = []
    var storageLoading = false
    var storageError: String?
    var performanceSamples: [PerformanceSample] = []
    var powerStatus = "Normal"
    var selectedModelRevision: String?
    var quarantineReason: String?
    var loadCompletedBytes: Int64?
    var loadTotalBytes: Int64?
    var loadStartedAt: Date?
    var resumesAfterWake = false
    var workspaceURL: URL?
    var pendingEdits: [PendingEdit] = []
    var activeToolActivity: String?
    private var generationTask: Task<Void, Never>?
    private var modelLoadTask: Task<Void, Never>?
    private var generationWatchdogTask: Task<Void, Never>?
    private var lastGenerationActivity = Date.distantPast
    private let generationStallTimeoutOverride: TimeInterval?
    private var runtimeOperationID = UUID()
    private var restartCircuitBreaker = RestartCircuitBreaker()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var idleUnloadTask: Task<Void, Never>?
    private var systemConditionTask: Task<Void, Never>?

    init(conversations: ConversationStore? = nil, service: MLXService? = nil, compatibilityStore: ModelCompatibilityStore? = nil, performanceStore: PerformanceStore? = nil, preferences: AppPreferences? = nil, localModelStore: LocalModelStore? = nil, generationStallTimeout: TimeInterval? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let demo = environment["MLX_DESK_UI_TESTING"] == "1"
        self.conversations = conversations ?? ConversationStore(seed: demo)
        self.service = service ?? MLXService(isDemo: demo)
        self.compatibilityStore = compatibilityStore ?? ModelCompatibilityStore()
        self.performanceStore = performanceStore ?? PerformanceStore()
        self.preferences = preferences ?? AppPreferences()
        self.localModelStore = localModelStore ?? LocalModelStore()
        self.generationStallTimeoutOverride = generationStallTimeout
        if environment["MLX_DESK_UI_TESTING_DOWNLOAD"] == "1" { runtime = .downloading(42) }
        else if demo { runtime = .ready }
        onboardingPresented = !demo && !OnboardingState.isComplete
        configureMemoryPressureMonitoring()
        startSystemConditionMonitoring()
        UpdateController.shared.startWhenConfigured()
        if !demo { resourceMonitor.start() }
    }

    var localModels: [MLXModel] { localModelStore.models }

    /// Opens a directory picker, validates the chosen folder looks like a loadable MLX
    /// model (same `ResourcePreflightValidator` check a downloaded snapshot gets), and
    /// adds it to the picker. Mirrors `chooseWorkspace()`'s use of a plain NSOpenPanel.
    func importLocalModel() {
        let panel = NSOpenPanel()
        panel.title = "Add Local MLX Model"
        panel.message = "Choose a folder containing config.json, tokenizer files, and .safetensors weights."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try MLXModel.local(directory: url)
            localModelStore.add(imported)
            selectedModel = imported
            modelChanged()
            localModelImportError = nil
        } catch {
            localModelImportError = error.localizedDescription
        }
    }

    func removeLocalModel(_ model: MLXModel) {
        localModelStore.remove(model)
        if selectedModel.id == model.id { selectedModel = MLXModel.curated[0]; modelChanged() }
    }

    func checkRuntime() async {
        runtime = .checking
        runtimePhase = .preflight
        runtime = await service.runtimeAvailable() ? .ready : .unavailable
        runtimePhase = runtime == .ready ? .idle : .failed
        selectedModelDownloaded = await service.modelIsDownloaded(selectedModel)
        setupPresented = runtime == .unavailable
    }

    func loadCatalog(force: Bool = false) async {
        guard (catalogModels.isEmpty || force), !catalogLoading else { return }
        catalogLoading = true
        // Fetched even if the analysis below fails: an old or broken bundled engine is
        // exactly the case where knowing *which* llmfit produced (or failed to produce)
        // these results matters most, and `--version` is near-instant either way.
        catalogEngineVersion = await catalogService.engineVersion()
        do {
            let snapshot = try await catalogService.load()
            catalogModels = snapshot.models
            catalogHardware = snapshot.hardware
            catalogUpdatedAt = .now
        }
        catch {
            catalogModels = MLXModel.curated
            catalogError = "\(error.localizedDescription) Showing the verified built-in catalog instead."
        }
        catalogLoading = false
    }

    /// Refreshes llmfit's own model database from Hugging Face, then re-runs the
    /// hardware analysis so anything newly fetched is reflected immediately. This
    /// is the only way the model list can improve between app updates -- the
    /// bundled binary's embedded list is otherwise frozen at build time -- so it's
    /// offered as an explicit action, never run automatically on a normal catalog load.
    func updateModelDatabase() async {
        guard !updatingModelDatabase else { return }
        updatingModelDatabase = true
        modelDatabaseUpdateResult = nil
        do {
            modelDatabaseUpdateResult = try await catalogService.updateModelDatabase()
            await loadCatalog(force: true)
        } catch {
            modelDatabaseUpdateResult = error.localizedDescription
        }
        updatingModelDatabase = false
    }

    func installRuntime() async {
        runtime = .starting
        do { try await service.install(); runtime = .ready; setupPresented = false }
        catch { runtime = .failed(error.localizedDescription); errorMessage = error.localizedDescription }
    }

    func startModel() async {
        guard restartCircuitBreaker.permitsAttempt() else {
            runtime = .failed("Automatic recovery paused")
            runtimePhase = .failed
            errorMessage = "MLX Desk stopped restarting the model after repeated failures. Choose a smaller model or wait five minutes before trying again."
            return
        }
        selectedModelRevision = await service.cachedRevision(for: selectedModel.repository)
        if let record = await compatibilityStore.record(for: selectedModel.repository), record.quarantined, record.revision == selectedModelRevision {
            quarantineReason = record.lastFailure
            runtime = .failed("Model quarantined")
            runtimePhase = .failed
            errorMessage = "This model revision failed compatibility checks twice and was paused to prevent a crash loop. Clear its quarantine or choose another model.\n\n\(record.lastFailure ?? "Unknown compatibility error")"
            return
        }
        quarantineReason = nil
        let operationID = UUID(); runtimeOperationID = operationID
        runtime = .starting
        runtimePhase = .preflight
        runtimeDetail = "Checking disk, memory, and model cache"
        loadStartedAt = .now; loadCompletedBytes = nil; loadTotalBytes = nil
        await DiagnosticsStore.shared.record(.init(category: "runtime", name: "start", operationID: operationID, modelID: selectedModel.repository))
        do {
            lastPreflight = try await service.preflight(model: selectedModel)
            try await withTaskCancellationHandler {
                try await service.start(model: selectedModel) { [weak self] progress in
                    await MainActor.run {
                        guard let self, self.runtimeOperationID == operationID else { return }
                        self.runtimePhase = progress.phase
                        self.loadCompletedBytes = progress.completedBytes
                        self.loadTotalBytes = progress.totalBytes
                        self.runtimeDetail = self.progressDetail(progress.detail)
                        if case .downloading(let percent) = progress.phase { self.runtime = .downloading(percent) }
                        else { self.runtime = .starting }
                    }
                }
            } onCancel: { [service] in Task { await service.stop() } }
            guard runtimeOperationID == operationID else { await service.stop(); return }
            selectedModelDownloaded = true
            runtime = .running
            runtimePhase = .ready
            runtimeDetail = "Readiness check passed"
            restartCircuitBreaker.reset()
            selectedModelRevision = await service.cachedRevision(for: selectedModel.repository)
            await compatibilityStore.recordSuccess(modelID: selectedModel.repository, revision: selectedModelRevision)
            lastHealth = await service.healthCheck(includeReadiness: false)
            await DiagnosticsStore.shared.record(.init(category: "runtime", name: "ready", operationID: operationID, modelID: selectedModel.repository))
            scheduleIdleUnload()
        } catch {
            guard runtimeOperationID == operationID else { return }
            await service.stop()
            restartCircuitBreaker.recordFailure()
            runtime = .failed(error.localizedDescription); runtimePhase = .failed; runtimeDetail = error.localizedDescription
            errorMessage = error.localizedDescription
            if compatibilityFailure(error) {
                let record = await compatibilityStore.recordCompatibilityFailure(modelID: selectedModel.repository, revision: selectedModelRevision, reason: error.localizedDescription)
                quarantineReason = record.quarantined ? record.lastFailure : nil
            }
            await DiagnosticsStore.shared.record(.init(category: "runtime", name: "start_failed", operationID: operationID,
                                                        modelID: selectedModel.repository, detail: error.localizedDescription))
        }
    }

    func beginModelStart() {
        modelLoadTask?.cancel()
        modelLoadTask = Task { [weak self] in await self?.startModel() }
    }

    func cancelModelLoad() {
        let wasDownloading: Bool = { if case .downloading = runtime { return true }; return false }()
        runtimeOperationID = UUID(); modelLoadTask?.cancel(); modelLoadTask = nil
        runtime = .ready; runtimePhase = .idle; runtimeDetail = wasDownloading ? "Download paused — start again to resume" : "Model loading cancelled"
        Task { await service.stop(); await DiagnosticsStore.shared.record(.init(category: "runtime", name: "load_cancelled", modelID: selectedModel.repository)) }
    }

    func modelChanged() {
        runtimeOperationID = UUID()
        modelLoadTask?.cancel(); modelLoadTask = nil
        let shouldStop: Bool
        switch runtime { case .running, .starting, .downloading: shouldStop = true; default: shouldStop = false }
        guard shouldStop else {
            Task { selectedModelDownloaded = await service.modelIsDownloaded(selectedModel) }
            return
        }
        // A generation in flight against the model being switched away from must be torn
        // down completely, not left to run or fail on its own: without this, its watchdog
        // task -- armed with a stall deadline that belongs to the OLD model/attempt -- keeps
        // ticking in the background and can fire later, misattributing "model became
        // unresponsive" to whatever the NEW model is doing at that point. Confirmed live:
        // switching models while a prior stall's watchdog was still counting down produced a
        // spurious failure banner on top of a brand new, perfectly healthy download.
        generationTask?.cancel(); generationTask = nil
        generationWatchdogTask?.cancel(); generationWatchdogTask = nil
        isGenerating = false
        runtime = .ready
        runtimePhase = .idle
        runtimeDetail = "Model selection changed"
        quarantineReason = nil; selectedModelRevision = nil
        Task { await service.stop() }
        Task { selectedModelDownloaded = await service.modelIsDownloaded(selectedModel) }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pendingAttachments.isEmpty), let id = conversations.selection,
              runtime == .running || ProcessInfo.processInfo.environment["MLX_DESK_UI_TESTING"] == "1" else { return }
        let attachments = pendingAttachments
        draft = ""; pendingAttachments = []
        conversations.append(.init(role: .user, content: Self.composeMessage(text: text, attachments: attachments)), to: id)
        conversations.append(.init(role: .assistant, content: ""), to: id); isGenerating = true
        runtimePhase = .generating
        lastGenerationActivity = .now
        startGenerationWatchdog(conversationID: id)
        let started = ContinuousClock.now
        generationTask = Task {
            do {
                guard let allMessages = conversations.selected?.messages.dropLast().map({ $0 }) else { return }
                let budget = max(1, settings.contextLength * 3)
                var used = 0
                let messages = allMessages.reversed().prefix { message in
                    used += message.content.count
                    return used <= budget
                }.reversed()
                var response = ""; var tokenEstimate = 0
                var firstTokenAt: ContinuousClock.Instant?
                var lastRender = Date.distantPast
                for try await chunk in await service.stream(
                    messages: Array(messages), settings: settings, workspaceURL: workspaceURL,
                    onProposeEdit: { [weak self] edit in await self?.stagePendingEdit(edit) },
                    onToolActivity: { [weak self] activity in await self?.setToolActivity(activity) }
                ) {
                    try Task.checkCancellation(); response += chunk; tokenEstimate += 1
                    lastGenerationActivity = .now
                    if firstTokenAt == nil {
                        firstTokenAt = .now
                        let wait = started.duration(to: .now).components
                        timeToFirstToken = Double(wait.seconds) + Double(wait.attoseconds) / 1e18
                    }
                    if Date().timeIntervalSince(lastRender) >= 0.10 {
                        conversations.updateLastAssistant(response, in: id)
                        lastRender = .now
                    }
                }
                conversations.updateLastAssistant(response, in: id)
                let elapsed = (firstTokenAt ?? started).duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                tokensPerSecond = seconds > 0.05 && tokenEstimate > 1 ? Double(tokenEstimate - 1) / seconds : nil
                if let tokensPerSecond, let timeToFirstToken {
                    await performanceStore.add(modelID: selectedModel.repository, tokensPerSecond: tokensPerSecond, firstTokenSeconds: timeToFirstToken)
                    performanceSamples = await performanceStore.all()
                }
                conversations.persist()
                runtimePhase = .ready
                scheduleIdleUnload()
            } catch is CancellationError { }
            catch {
                await service.stop()
                let message = error.localizedDescription
                runtime = .failed(message)
                runtimePhase = .failed
                runtimeDetail = "Generation timed out or the runtime disconnected"
                restartCircuitBreaker.recordFailure()
                errorMessage = "The model stopped responding. Its server was reset, so you can use Try Again.\n\n\(message)"
                await DiagnosticsStore.shared.record(.init(category: "generation", name: "failed", modelID: selectedModel.repository, detail: message))
            }
            isGenerating = false
            activeToolActivity = nil
            generationWatchdogTask?.cancel(); generationWatchdogTask = nil
        }
    }

    func stopGeneration() {
        generationTask?.cancel(); generationTask = nil; isGenerating = false
        activeToolActivity = nil
        generationWatchdogTask?.cancel(); generationWatchdogTask = nil
        runtimePhase = runtime == .running ? .ready : .idle
        conversations.persist()
        Task { await DiagnosticsStore.shared.record(.init(category: "generation", name: "cancelled", modelID: selectedModel.repository)) }
    }

    /// Called from `applicationShouldTerminate` before the app is allowed to quit. Gives
    /// any in-flight generation a bounded window to wind down and persists whatever
    /// response text has streamed in so far, but deliberately does NOT release the native
    /// MLX session/container itself (an earlier version of this method called
    /// `service.stop()` here, which is exactly what caused a second, different crash: when
    /// the wait timed out because MLX's own background compute thread hadn't honored
    /// cancellation yet, `service.stop()` released the container out from under that still
    /// -running thread, which then segfaulted inside MLX's compiled-kernel cache
    /// (`CompilerCache`) on a now-freed object -- confirmed live, reproduced by quitting
    /// mid-generation). MLX's native generation runs on its own detached task, off the
    /// structured-concurrency tree `generationTask` belongs to, so cancelling
    /// `generationTask` only asks that task to stop -- it doesn't guarantee the underlying
    /// compute has actually finished by the time we give up waiting. Leaving the
    /// (possibly still in use) native objects alone and simply letting the process exit
    /// shortly after is safe: see `AppDelegate.applicationWillTerminate`, which is what
    /// actually closes this race by skipping process teardown entirely rather than trying
    /// to win it.
    func prepareForTermination() async {
        generationWatchdogTask?.cancel(); generationWatchdogTask = nil
        if let task = generationTask {
            generationTask = nil
            task.cancel()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
        }
        isGenerating = false
        conversations.persist()
    }

    func completeOnboarding() {
        OnboardingState.isComplete = true; onboardingPresented = false; catalogPresented = true
    }

    /// Maximum bytes read from any one attached file before it is truncated. Keeps a
    /// large log or asset from silently consuming the whole context budget in `send()`,
    /// which trims by character count but only after this has already built the string.
    private static let attachmentByteLimit = 200_000

    /// Reads each URL as UTF-8 text and stages it for the next send. Skips files that
    /// don't decode as text (binaries, images) rather than failing the whole batch, and
    /// surfaces one combined error through the existing alert if every file was skipped.
    func addAttachments(from urls: [URL]) async {
        var added: [ComposerAttachment] = []
        var skipped: [String] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { skipped.append(url.lastPathComponent); continue }
            let truncated = data.count > Self.attachmentByteLimit
            let slice = truncated ? data.prefix(Self.attachmentByteLimit) : data[...]
            guard let text = String(data: slice, encoding: .utf8) else { skipped.append(url.lastPathComponent); continue }
            added.append(.init(filename: url.lastPathComponent, text: text, truncated: truncated))
        }
        pendingAttachments.append(contentsOf: added)
        if !skipped.isEmpty {
            errorMessage = "Couldn't read as text, so \(skipped.count == 1 ? "it wasn't" : "they weren't") attached: \(skipped.joined(separator: ", "))"
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Folds staged files into the message text as fenced code blocks. Plain string
    /// composition, not a separate wire format: MLXService only ever sends message
    /// content as text (see MLXService.stream), for both the native runtime and the
    /// legacy HTTP server, so this is the only place file content can enter a prompt.
    fileprivate static func composeMessage(text: String, attachments: [ComposerAttachment]) -> String {
        guard !attachments.isEmpty else { return text }
        var parts = text.isEmpty ? [] : [text]
        for attachment in attachments {
            let fence = "```" + (attachment.filename.split(separator: ".").last.map(String.init) ?? "")
            var block = "**\(attachment.filename)**\n\(fence)\n\(attachment.text)\n```"
            if attachment.truncated { block += "\n_(truncated at \(Self.attachmentByteLimit / 1000) KB)_" }
            parts.append(block)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Opens an NSOpenPanel scoped to directories, matching the NSSavePanel
    /// convention already used for diagnostics export (ModelInspector.swift).
    /// Setting `workspaceURL` is what turns on the read/propose-edit tools for
    /// the next generation -- see MLXService.stream's tools: parameter.
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open Workspace"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspaceURL = url
        pendingEdits.removeAll()
    }

    func closeWorkspace() {
        workspaceURL = nil
        pendingEdits.removeAll()
    }

    /// Called (via a `@Sendable` closure, hence `@MainActor` hop) from the
    /// `propose_edit` tool's handler in WorkspaceTools.swift when the model
    /// proposes a change. Never writes to disk itself.
    @MainActor
    func stagePendingEdit(_ edit: PendingEdit) {
        pendingEdits.append(edit)
    }

    /// Drives the "using read_file(App.swift)…" transcript indicator -- see
    /// WorkspaceTools.makeToolSet's onActivity parameter.
    @MainActor
    func setToolActivity(_ description: String?) {
        activeToolActivity = description
    }

    /// Writes `edit.newContent` to disk, re-validating containment within the
    /// current workspace even though WorkspaceTools already checked at proposal
    /// time -- defense in depth against the workspace having changed (or the
    /// edit being replayed) between proposal and this explicit user action.
    func applyEdit(_ edit: PendingEdit) {
        defer { pendingEdits.removeAll { $0.id == edit.id } }
        guard let workspaceURL else { return }
        do {
            let fileURL = try WorkspaceTools.resolve(edit.path, in: workspaceURL)
            try edit.newContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't apply the edit to \(edit.path): \(error.localizedDescription)"
        }
    }

    func rejectEdit(_ edit: PendingEdit) {
        pendingEdits.removeAll { $0.id == edit.id }
    }

    func preferencesChanged() { scheduleIdleUnload() }

    func loadStorage() async {
        storageLoading = true; cachedModels = await service.cachedModels(); storageLoading = false
    }

    func deleteCachedModel(_ entry: CachedModelEntry) async {
        do {
            try await service.deleteCachedModel(repository: entry.repository)
            await compatibilityStore.clear(modelID: entry.repository)
            await loadStorage()
        } catch { storageError = error.localizedDescription }
    }

    func verifyCachedModel(_ entry: CachedModelEntry) async -> String {
        do { try await service.verifyCachedModel(repository: entry.repository); return "Verified" }
        catch { return error.localizedDescription }
    }

    func revealCachedModel(_ entry: CachedModelEntry) async {
        let url = await service.cacheURL(repository: entry.repository)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func resumeCachedModel(_ entry: CachedModelEntry, startImmediately: Bool = true) async {
        // Look up the real total size from the hardware-matched catalog first -- loading
        // it if we haven't yet -- so the download percent shown while resuming reflects
        // actual remaining bytes instead of quietly treating "already downloaded" as "done".
        if catalogModels.isEmpty { await loadCatalog() }
        if let known = catalogModels.first(where: { $0.repository == entry.repository }) {
            selectedModel = known
        } else {
            selectedModel = MLXModel(
                repository: entry.repository,
                displayName: entry.repository.split(separator: "/").last.map(String.init) ?? entry.repository,
                detail: "Cached MLX model", size: ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file),
                memory: "Calculated during preflight", downloadBytes: max(entry.bytes, 1), recommended: false,
                downloadSizeIsEstimated: true
            )
        }
        modelChanged()
        if startImmediately { beginModelStart() }
        storagePresented = false
    }

    func loadPerformanceHistory() async { performanceSamples = await performanceStore.all() }
    func clearPerformanceHistory() async { await performanceStore.clear(); performanceSamples = [] }

    func compatibilityReportData() async throws -> Data {
        struct Report: Codable {
            let generatedAt: Date; let hardware: FitSystem?; let modelCatalogEngineVersion: String?
            let selectedModel: String; let revision: String?
            let preflight: PreflightReport?; let health: RuntimeHealth?; let cachedModels: [String]
            let privacy: String
        }
        let report = Report(generatedAt: .now, hardware: catalogHardware, modelCatalogEngineVersion: catalogEngineVersion, selectedModel: selectedModel.repository, revision: selectedModelRevision, preflight: lastPreflight, health: lastHealth, cachedModels: cachedModels.map(\.repository), privacy: "No prompts or responses included")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    func refreshHealth(includeReadiness: Bool = false) async {
        lastHealth = await service.healthCheck(includeReadiness: includeReadiness)
    }

    func supportBundleData() async throws -> Data {
        try await DiagnosticsStore.shared.export(model: selectedModel, runtime: runtime, phase: runtimePhase, preflight: lastPreflight, modelCatalogEngineVersion: catalogEngineVersion)
    }

    func clearSelectedModelQuarantine() async {
        await compatibilityStore.clear(modelID: selectedModel.repository)
        quarantineReason = nil
        runtime = .ready; runtimePhase = .idle; runtimeDetail = "Compatibility quarantine cleared"
        await DiagnosticsStore.shared.record(.init(category: "model", name: "quarantine_cleared", modelID: selectedModel.repository))
    }

    func systemWillSleep() async {
        resumesAfterWake = runtime == .running
        guard resumesAfterWake else { return }
        stopGeneration(); runtimeOperationID = UUID()
        await service.stop()
        runtime = .ready; runtimePhase = .idle; runtimeDetail = "Model unloaded while this Mac sleeps"
        await DiagnosticsStore.shared.record(.init(category: "lifecycle", name: "sleep_unload", modelID: selectedModel.repository))
    }

    func systemDidWake() async {
        guard resumesAfterWake else { return }
        resumesAfterWake = false
        runtimePhase = .recovering(attempt: 1); runtimeDetail = "Reloading the model after wake"
        await DiagnosticsStore.shared.record(.init(category: "lifecycle", name: "wake_recovery", modelID: selectedModel.repository))
        await startModel()
    }

    func handleCriticalMemoryPressure() async {
        guard runtime == .running, !isGenerating else { return }
        runtimeOperationID = UUID(); await service.stop()
        runtime = .ready; runtimePhase = .idle; runtimeDetail = "Model unloaded because memory pressure was critical"
        await DiagnosticsStore.shared.record(.init(category: "lifecycle", name: "memory_pressure_unload", modelID: selectedModel.repository))
    }

    func evaluateSystemConditions(thermal: ProcessInfo.ThermalState, lowPower: Bool) async {
        powerStatus = lowPower ? "Low Power Mode" : thermal == .nominal ? "Normal" : "Thermal pressure"
        let shouldUnload = (preferences.unloadOnLowPower && lowPower) || (preferences.protectThermals && (thermal == .serious || thermal == .critical))
        guard shouldUnload, runtime == .running, !isGenerating else { return }
        runtimeOperationID = UUID(); await service.stop(); runtime = .ready; runtimePhase = .idle
        runtimeDetail = lowPower ? "Model unloaded for Low Power Mode" : "Model unloaded to let this Mac cool down"
        await DiagnosticsStore.shared.record(.init(category: "lifecycle", name: lowPower ? "low_power_unload" : "thermal_unload", modelID: selectedModel.repository))
    }

    private func progressDetail(_ detail: String) -> String {
        guard let completed = loadCompletedBytes, let total = loadTotalBytes, total > 0 else { return detail }
        let elapsed = Date.now.timeIntervalSince(loadStartedAt ?? .now)
        return "\(detail) · \(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · \(Int(elapsed))s"
    }

    private func compatibilityFailure(_ error: Error) -> Bool {
        if let preflight = error as? PreflightError, case .invalidModelCache = preflight { return true }
        if let service = error as? ServiceError, case .incompatibleTokenizer = service { return true }
        return false
    }

    private func configureMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.handleCriticalMemoryPressure() }
        }
        source.resume(); memoryPressureSource = source
    }

    /// How long generation may go without producing a token before the watchdog
    /// declares it stalled and unloads the model. A flat 45s was too tight for
    /// larger models: first-token latency after a fresh load includes one-time
    /// Metal-kernel compilation that scales with model size, and on a loaded Mac
    /// a ~22GB model was observed genuinely stalling past 45s under real system
    /// memory pressure with no actual hang -- just legitimate compile + swap
    /// cost. Scales with the selected model's own memory footprint instead of a
    /// single constant, floored at the old 45s and capped so a truly-stuck model
    /// still gets caught within a few minutes rather than never.
    ///
    /// A 27B local import (see LocalModelStore) was confirmed live to still be
    /// mid-warmup-compile and killed at the formula's own 180s ceiling below --
    /// `memoryGB * 6` for a ~17GB-while-running model only reaches ~104s, nowhere
    /// near that ceiling, so raising the cap alone wouldn't have helped; the
    /// per-GB multiplier itself is too low at this scale. Rather than re-tune
    /// that multiplier against a single data point and risk under/over-fitting
    /// catalog models it already works for, local imports get their own flat,
    /// generous budget: they're exactly the case (a never-before-run custom
    /// conversion) where first-compile cost is least likely to already be
    /// amortized by a warm shader cache, and a user who just hand-picked a
    /// folder of weights is likely to want more patience before an automatic
    /// unload, not less.
    private var generationStallTimeout: TimeInterval {
        if let generationStallTimeoutOverride { return generationStallTimeoutOverride }
        if selectedModel.isLocal { return 240 }
        let memoryGB = Self.parsedGB(from: selectedModel.memory) ?? 8
        return min(180, max(45, memoryGB * 6))
    }

    private static func parsedGB(from text: String) -> Double? {
        guard let match = text.firstMatch(of: /([0-9]+(?:\.[0-9]+)?)/), let value = Double(match.1) else { return nil }
        return value
    }

    private func startGenerationWatchdog(conversationID: UUID) {
        generationWatchdogTask?.cancel()
        generationWatchdogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, self.isGenerating else { return }
                guard Date.now.timeIntervalSince(self.lastGenerationActivity) >= self.generationStallTimeout else { continue }
                self.generationTask?.cancel(); self.generationTask = nil
                await self.service.stop()
                self.isGenerating = false; self.runtime = .failed("Generation stalled"); self.runtimePhase = .failed
                self.runtimeDetail = "No model output arrived for \(Int(self.generationStallTimeout)) seconds"
                self.errorMessage = "The model stopped producing output and was unloaded automatically. Try again or choose a smaller model."
                self.conversations.updateLastAssistant("Generation stopped because the model became unresponsive.", in: conversationID)
                self.conversations.persist()
                await DiagnosticsStore.shared.record(.init(category: "generation", name: "watchdog_timeout", modelID: self.selectedModel.repository, detail: self.runtimeDetail))
                return
            }
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        guard preferences.idleUnloadMinutes > 0 else { return }
        let delay = preferences.idleUnloadMinutes
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay * 60))
            guard let self, !Task.isCancelled, self.runtime == .running, !self.isGenerating else { return }
            await self.service.stop(); self.runtime = .ready; self.runtimePhase = .idle
            self.runtimeDetail = "Model unloaded after \(delay) minutes idle"
            await DiagnosticsStore.shared.record(.init(category: "lifecycle", name: "idle_unload", modelID: self.selectedModel.repository))
        }
    }

    private func startSystemConditionMonitoring() {
        systemConditionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.evaluateSystemConditions(thermal: ProcessInfo.processInfo.thermalState, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}
