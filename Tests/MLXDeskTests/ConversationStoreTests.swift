import Foundation
import Testing
@testable import MLXDesk

/// Polls `condition` instead of sleeping a fixed duration: returns as soon as it's true,
/// rather than gambling a single fixed sleep is long enough on whatever machine runs this
/// (demo-mode generation legitimately takes longer under a cold, loaded CI runner than on
/// an idle local Mac -- a fixed sleep either wastes time or, if too short, flakes).
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
struct ConversationStoreTests {
    @Test func createsInitialConversation() {
        let store = ConversationStore(fileURL: nil)
        #expect(store.conversations.count == 1)
        #expect(store.selection != nil)
    }

    @Test func firstPromptBecomesTitle() {
        let store = ConversationStore(fileURL: nil)
        let id = store.selection!
        store.append(.init(role: .user, content: "Build a beautiful settings screen"), to: id)
        #expect(store.selected?.title == "Build a beautiful settings screen")
    }

    @Test func searchFindsTitlesAndMessages() {
        let store = ConversationStore(fileURL: nil)
        store.append(.init(role: .user, content: "Fix the authentication middleware"), to: store.selection!)
        store.searchText = "authentication"
        #expect(store.filtered.count == 1)
        store.searchText = "missing"
        #expect(store.filtered.isEmpty)
    }

    @Test func deletingLastConversationCreatesReplacement() {
        let store = ConversationStore(fileURL: nil)
        store.remove(store.selection!)
        #expect(store.conversations.count == 1)
        #expect(store.selection != nil)
    }

    @Test func clearsCurrentConversation() {
        let store = ConversationStore(fileURL: nil)
        let id = store.selection!
        store.append(.init(role: .user, content: "Temporary prompt"), to: id)
        store.clearMessages(in: id)
        #expect(store.selected?.messages.isEmpty == true)
        #expect(store.selected?.title == "New conversation")
    }

    @Test func persistsAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "mlxdesk-\(UUID()).json")
        let writer = ConversationStore(fileURL: url)
        writer.append(.init(role: .user, content: "Persist me"), to: writer.selection!)
        let reader = ConversationStore(fileURL: url)
        #expect(reader.selected?.messages.first?.content == "Persist me")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func repairsInterruptedResponseOnLaunch() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "mlxdesk-interrupted-\(UUID()).json")
        let conversation = Conversation(title: "Interrupted", messages: [.init(role: .assistant, content: "")])
        try JSONEncoder().encode([conversation]).write(to: url)
        let store = ConversationStore(fileURL: url)
        #expect(store.selected?.messages.last?.content.contains("interrupted") == true)
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
struct AppModelTests {
    @Test func demoRuntimeAndStreaming() async throws {
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        await model.checkRuntime(); #expect(model.runtime == .ready)
        await model.startModel(); #expect(model.runtime == .running)
        model.draft = "Write a greeting"; model.send()
        try await waitUntil { !model.isGenerating }
        #expect(model.conversations.selected?.messages.count == 2)
        #expect(model.conversations.selected?.messages.last?.content.contains("swift") == true)
        #expect(model.isGenerating == false)
    }

    @Test func emptyDraftDoesNotSend() async {
        let store = ConversationStore(fileURL: nil)
        let model = AppModel(conversations: store, service: MLXService(isDemo: true))
        await model.startModel(); model.draft = "   "; model.send()
        #expect(store.selected?.messages.isEmpty == true)
    }

    @Test func generationCanBeCancelled() async throws {
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        await model.startModel(); model.draft = "Generate something"; model.send()
        #expect(model.isGenerating)
        model.stopGeneration()
        #expect(model.isGenerating == false)
    }

    @Test func launchFailureDoesNotLeaveAppBusy() async {
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true, injectedFault: .startFailure))
        await model.startModel()
        if case .failed = model.runtime {} else { Issue.record("Expected a failed runtime") }
        #expect(model.runtimePhase == .failed)
        #expect(model.isGenerating == false)
        #expect(model.errorMessage?.contains("reliability test") == true)
    }

    @Test func generationFailureReturnsControlToUser() async throws {
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true, injectedFault: .streamFailure))
        await model.startModel()
        model.draft = "Trigger a controlled failure"
        model.send()
        try await waitUntil { !model.isGenerating }
        #expect(model.isGenerating == false)
        if case .failed = model.runtime {} else { Issue.record("Expected a failed runtime") }
        #expect(model.runtimePhase == .failed)
    }

    @Test func sleepWakeUnloadsAndRecoversModel() async {
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        await model.startModel()
        await model.systemWillSleep()
        #expect(model.runtime == .ready)
        #expect(model.resumesAfterWake)
        await model.systemDidWake()
        #expect(model.runtime == .running)
        #expect(!model.resumesAfterWake)
    }

    @Test func criticalMemoryPressureUnloadsIdleModel() async {
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        await model.startModel()
        await model.handleCriticalMemoryPressure()
        #expect(model.runtime == .ready)
        #expect(model.runtimeDetail.contains("memory pressure"))
    }

    @Test func stalledGenerationIsStoppedByWatchdog() async throws {
        let service = MLXService(isDemo: true, injectedFault: .streamStall)
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: service, generationStallTimeout: 0.2)
        await model.startModel(); model.draft = "stall"; model.send()
        try await waitUntil { model.runtimePhase == .failed }
        #expect(!model.isGenerating)
        #expect(model.runtimePhase == .failed)
        #expect(model.errorMessage?.contains("stopped producing output") == true)
    }

    @Test func switchingModelsRejectsStaleStartupCompletion() async throws {
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        let startup = Task { await model.startModel() }
        try await Task.sleep(for: .milliseconds(100))
        model.selectedModel = MLXModel.curated[1]
        model.modelChanged()
        await startup.value
        #expect(model.runtime != .running)
        #expect(model.selectedModel == MLXModel.curated[1])
    }

    @Test func switchingModelsCancelsAStalePriorGenerationWatchdog() async throws {
        let service = MLXService(isDemo: true, injectedFault: .streamStall)
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: service, generationStallTimeout: 0.2)
        await model.startModel()
        model.draft = "stall"; model.send()
        #expect(model.isGenerating)

        model.selectedModel = MLXModel.curated[1]
        model.modelChanged()
        #expect(!model.isGenerating)

        // Wait well past the original 0.2s stall window. Before this fix, modelChanged()
        // left the prior generation's watchdog task running -- still counting down against
        // the OLD generation's lastGenerationActivity -- so it would fire here regardless of
        // having switched away, setting a spurious "model became unresponsive" failure on
        // top of whatever the newly selected model is doing.
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.errorMessage == nil)
        if case .failed = model.runtime { Issue.record("Stale watchdog fired after switching models") }
    }

    @Test func modelLoadingCanBeCancelled() async throws {
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        model.beginModelStart()
        try await Task.sleep(for: .milliseconds(100))
        model.cancelModelLoad()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.runtime == .ready)
        #expect(model.runtimeDetail == "Model loading cancelled")
    }
}

struct ModelCatalogTests {
    @Test func catalogHasVerifiedOfflineFallback() {
        #expect(!MLXModel.curated.isEmpty)
        #expect(MLXModel.curated.allSatisfy { $0.trustLevel.isTrusted })
    }

    @Test func decodesLLMFitModelAndBuildsAppModel() throws {
        let data = #"{"system":{"cpu_name":"Apple M1 Max","cpu_cores":10,"total_ram_gb":32,"available_ram_gb":14,"gpu_name":"Apple M1 Max","gpu_available_gb":24.9,"backend":"Metal"},"models":[{"name":"mlx-community/Test-4bit","provider":"mlx-community","parameter_count":"7B","fit_level":"Perfect","estimated_tps":25.5,"memory_required_gb":8.2,"best_quant":"mlx-4bit","runtime":"MLX","score":91.0}]}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(LLMFitResponse.self, from: data)
        let fit = response.models[0]
        #expect(response.system.totalRAMGB == 32)
        #expect(fit.isMLXRepository)
        #expect(fit.appModel.fitLevel == "Perfect")
        #expect(fit.appModel.estimatedTPS == 25.5)
    }

    @Test func bundledCatalogRulesExcludeNonMLXAndTooTight() throws {
        let nonMLX = FitModel(name: "org/model", provider: "org", parameterCount: "7B", fitLevel: "Perfect", estimatedTPS: 10, memoryRequiredGB: 8, bestQuant: "Q4", runtime: "llama.cpp", score: 80)
        let tooTight = FitModel(name: "mlx-community/huge", provider: "mlx-community", parameterCount: "100B", fitLevel: "Too Tight", estimatedTPS: 1, memoryRequiredGB: 60, bestQuant: "mlx-4bit", runtime: "MLX", score: 50)
        #expect(nonMLX.isMLXRepository == false)
        #expect(tooTight.isMLXRepository)
        #expect(tooTight.fitLevel == "Too Tight")
    }
}

struct MessageExportTests {
    @Test func createsSafeMarkdownFilename() {
        #expect(MessageExport.filename(for: "# Build: a / library?\nMore") == "Build a  library.md")
        #expect(MessageExport.filename(for: "***") == "LLM Response.md")
    }
}

@MainActor
struct ComposerAttachmentTests {
    @Test func attachedFileTextIsFoldedIntoTheSentMessage() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "attachment-\(UUID()).swift")
        try "func greet() { print(\"hi\") }".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        await model.startModel()
        await model.addAttachments(from: [url])
        #expect(model.pendingAttachments.count == 1)
        #expect(model.pendingAttachments[0].filename == url.lastPathComponent)

        model.draft = "Explain this"
        model.send()
        let sent = model.conversations.selected?.messages.first?.content
        #expect(sent?.contains("Explain this") == true)
        #expect(sent?.contains(url.lastPathComponent) == true)
        #expect(sent?.contains("func greet()") == true)
        #expect(model.pendingAttachments.isEmpty)
    }

    @Test func attachmentsAloneAreEnoughToSendWithoutTypedText() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "attachment-\(UUID()).txt")
        try "log line one".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        await model.startModel()
        await model.addAttachments(from: [url])
        model.draft = ""
        model.send()
        #expect(model.conversations.selected?.messages.first?.content.contains("log line one") == true)
    }

    @Test func nonTextFilesAreSkippedWithAnErrorInstead() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "attachment-\(UUID()).bin")
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD, 0x00, 0x01])
        try? invalidUTF8.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        await model.addAttachments(from: [url])
        #expect(model.pendingAttachments.isEmpty)
        #expect(model.errorMessage?.contains(url.lastPathComponent) == true)
    }

    @Test func removingAnAttachmentDropsItFromTheQueue() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "attachment-\(UUID()).txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        await model.addAttachments(from: [url])
        let id = try #require(model.pendingAttachments.first?.id)
        model.removeAttachment(id)
        #expect(model.pendingAttachments.isEmpty)
    }
}

struct ModelPurposeTests {
    @Test func classifiesCommonModelPurposes() {
        let coder = MLXModel(repository: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", displayName: "Qwen Coder", detail: "", size: "", memory: "", downloadBytes: 0, recommended: false)
        #expect(coder.bestFor.contains("Writing code"))

        let vision = MLXModel(repository: "mlx-community/Qwen2.5-VL-7B-4bit", displayName: "Qwen VL", detail: "", size: "", memory: "", downloadBytes: 0, recommended: false)
        #expect(vision.bestFor.contains("images"))

        let small = MLXModel(repository: "mlx-community/Llama-3.2-1B-Instruct-4bit", displayName: "Llama 1B", detail: "", size: "", memory: "", downloadBytes: 0, recommended: false, parameters: "1B")
        #expect(small.bestFor.contains("Fast chat"))
        #expect(small.trustLevel == .verifiedConversion)

        let community = MLXModel(repository: "someone/Experimental-MLX-4bit", displayName: "Experimental", detail: "", size: "", memory: "", downloadBytes: 0, recommended: false)
        #expect(community.trustLevel == .community)
    }
}

struct ReliabilityPrimitiveTests {
    @Test func circuitBreakerStopsCrashLoopsAndRecoversAfterWindow() {
        var breaker = RestartCircuitBreaker(maximumFailures: 2, window: 300)
        let start = Date(timeIntervalSince1970: 1_000)
        let initiallyPermitted = breaker.permitsAttempt(now: start)
        #expect(initiallyPermitted)
        breaker.recordFailure(now: start)
        breaker.recordFailure(now: start.addingTimeInterval(10))
        let blockedAfterFailures = breaker.permitsAttempt(now: start.addingTimeInterval(20))
        let permittedAfterWindow = breaker.permitsAttempt(now: start.addingTimeInterval(400))
        #expect(!blockedAfterFailures)
        #expect(permittedAfterWindow)
    }

    @Test func diagnosticExportExcludesConversationContent() async throws {
        let model = MLXModel.curated[0]
        await DiagnosticsStore.shared.record(.init(category: "test", name: "safe", modelID: model.repository, detail: "runtime-only"))
        let data = try await DiagnosticsStore.shared.export(model: model, runtime: .ready, phase: .idle, preflight: nil, modelCatalogEngineVersion: "1.1.9")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Prompts and model responses are excluded"))
        #expect(!text.contains("secret prompt"))
    }

    @Test func repeatedCompatibilityFailuresQuarantineOnlyThatRevision() async {
        let store = ModelCompatibilityStore(fileURL: nil)
        let first = await store.recordCompatibilityFailure(modelID: "model", revision: "a", reason: "bad tokenizer")
        let second = await store.recordCompatibilityFailure(modelID: "model", revision: "a", reason: "bad tokenizer")
        let newRevision = await store.recordCompatibilityFailure(modelID: "model", revision: "b", reason: "bad tokenizer")
        #expect(!first.quarantined)
        #expect(second.quarantined)
        #expect(!newRevision.quarantined)
        #expect(newRevision.failureCount == 1)
    }

    @Test func demoRuntimeSurvivesRepeatedStreaming() async throws {
        let service = MLXService(isDemo: true)
        for _ in 0..<10 {
            var output = ""
            for try await chunk in await service.stream(messages: [.init(role: .user, content: "test")], settings: .init()) { output += chunk }
            #expect(output.contains("swift"))
        }
    }

    @Test func lowDiskPreflightFailsBeforeDownload() {
        #expect(throws: PreflightError.insufficientDisk(required: 20_000, available: 1_000)) {
            try ResourcePreflightValidator.requireDisk(available: 1_000, required: 20_000, alreadyDownloaded: false)
        }
    }

    @Test func corruptCacheIsRejectedBeforeModelLoad() throws {
        let snapshot = FileManager.default.temporaryDirectory.appending(path: "mlxdesk-corrupt-\(UUID())")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        #expect(throws: PreflightError.invalidModelCache("config.json is missing.")) {
            try ResourcePreflightValidator.validateSnapshot(at: snapshot)
        }
    }

    // A partial multi-shard download: the native downloader moves each shard into place only
    // once it's fully written, so a still-missing shard leaves no ".incomplete" marker anywhere --
    // a plain directory listing looks identical to "download in progress" and to "nothing wrong".
    // Confirmed live: a model sitting at ~7% of its real size read back as fully downloaded before
    // this check existed. These tests build a snapshot directory by hand (config.json, a tokenizer
    // file, and an index listing shards that may or may not actually be present) rather than
    // downloading anything real.
    private func makeMultiShardSnapshot(presentShards: [String], indexedShards: [String]) throws -> URL {
        let snapshot = FileManager.default.temporaryDirectory.appending(path: "mlxdesk-shards-\(UUID())")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try "{}".write(to: snapshot.appending(path: "config.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: snapshot.appending(path: "tokenizer.json"), atomically: true, encoding: .utf8)
        for shard in presentShards {
            try "shard".write(to: snapshot.appending(path: shard), atomically: true, encoding: .utf8)
        }
        let weightMap = Dictionary(uniqueKeysWithValues: indexedShards.enumerated().map { ("tensor.\($0.offset)", $0.element) })
        let index = try JSONSerialization.data(withJSONObject: ["weight_map": weightMap])
        try index.write(to: snapshot.appending(path: "model.safetensors.index.json"))
        return snapshot
    }

    @Test func snapshotMissingAShardListedInTheIndexIsRejected() throws {
        let snapshot = try makeMultiShardSnapshot(
            presentShards: ["model-00001-of-00002.safetensors"],
            indexedShards: ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"])
        defer { try? FileManager.default.removeItem(at: snapshot) }
        #expect(!ResourcePreflightValidator.isComplete(at: snapshot))
        #expect(throws: (any Error).self) { try ResourcePreflightValidator.validateSnapshot(at: snapshot) }
    }

    @Test func snapshotWithEveryIndexedShardPresentIsAccepted() throws {
        let shards = ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]
        let snapshot = try makeMultiShardSnapshot(presentShards: shards, indexedShards: shards)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        #expect(ResourcePreflightValidator.isComplete(at: snapshot))
        #expect(throws: Never.self) { try ResourcePreflightValidator.validateSnapshot(at: snapshot) }
    }

    @Test func singleFileModelWithNoShardIndexIsAcceptedOnFilePresenceAlone() throws {
        let snapshot = FileManager.default.temporaryDirectory.appending(path: "mlxdesk-singlefile-\(UUID())")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        try "{}".write(to: snapshot.appending(path: "config.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: snapshot.appending(path: "tokenizer.json"), atomically: true, encoding: .utf8)
        try "weights".write(to: snapshot.appending(path: "model.safetensors"), atomically: true, encoding: .utf8)
        #expect(ResourcePreflightValidator.isComplete(at: snapshot))
    }
}

@MainActor
struct ProductizationTests {
    @Test func performanceHistoryPersistsWithoutConversationText() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "mlxdesk-performance-\(UUID()).json")
        let writer = PerformanceStore(fileURL: url)
        await writer.add(modelID: "mlx-community/test", tokensPerSecond: 12.5, firstTokenSeconds: 0.7)
        let reader = PerformanceStore(fileURL: url)
        let samples = await reader.all()
        #expect(samples.count == 1)
        #expect(samples[0].tokensPerSecond == 12.5)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("prompt"))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func lifecyclePreferencesPersist() {
        let name = "MLXDeskTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let preferences = AppPreferences(defaults: defaults)
        preferences.idleUnloadMinutes = 30; preferences.unloadOnLowPower = false; preferences.updateChannel = "Preview"
        let loaded = AppPreferences(defaults: defaults)
        #expect(loaded.idleUnloadMinutes == 30)
        #expect(!loaded.unloadOnLowPower)
        #expect(loaded.updateChannel == "Preview")
        defaults.removePersistentDomain(forName: name)
    }

    @Test func thermalProtectionUnloadsIdleModel() async {
        let defaults = UserDefaults(suiteName: "MLXDeskThermal-\(UUID())")!
        let preferences = AppPreferences(defaults: defaults); preferences.protectThermals = true
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true), preferences: preferences)
        await model.startModel(); await model.evaluateSystemConditions(thermal: .serious, lowPower: false)
        #expect(model.runtime == .ready)
        #expect(model.runtimeDetail.contains("cool down"))
    }

    @Test func compatibilityReportIsRedacted() async throws {
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        model.conversations.append(.init(role: .user, content: "secret prompt"), to: model.conversations.selection!)
        let text = String(decoding: try await model.compatibilityReportData(), as: UTF8.self)
        #expect(text.contains("No prompts or responses included"))
        #expect(!text.contains("secret prompt"))
    }

    @Test func localizedInfrastructureLoadsEnglishResources() {
        #expect(L10n.storageTitle == "Model Storage")
        #expect(L10n.onboardingTitle.contains("Private AI"))
    }

    @Test func storageManagerNeverClaimsUnrelatedCaches() async {
        let entries = await MLXService(isDemo: true).cachedModels()
        #expect(entries.allSatisfy { $0.repository.localizedCaseInsensitiveContains("mlx") })
    }

    @Test func updaterRemainsDormantWithoutSignedConfiguration() {
        #expect(!UpdateController.shared.isConfigured)
    }

    @Test func resumingAModelKnownToTheCatalogUsesItsRealDownloadSize() async {
        let known = MLXModel(repository: "mlx-community/Known-4bit", displayName: "Known", detail: "", size: "", memory: "",
                              downloadBytes: 12_000_000_000, recommended: false)
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        model.catalogModels = [known]
        await model.resumeCachedModel(.init(repository: known.repository, bytes: 3_000_000_000, incomplete: true, modifiedAt: nil))
        #expect(model.selectedModel.downloadBytes == 12_000_000_000)
        #expect(!model.selectedModel.downloadSizeIsEstimated)
    }

    @Test func resumingAModelUnknownToTheCatalogMarksItsSizeAsEstimated() async {
        let model = AppModel(conversations: ConversationStore(fileURL: nil), service: MLXService(isDemo: true))
        model.catalogModels = MLXModel.curated // non-empty, so loadCatalog() is not invoked, and it doesn't contain this repository
        await model.resumeCachedModel(.init(repository: "someone/Not-In-Catalog-4bit", bytes: 3_000_000_000, incomplete: true, modifiedAt: nil))
        #expect(model.selectedModel.downloadSizeIsEstimated)
    }
}

struct RuntimeProgressLabelTests {
    @Test func downloadPercentLabelHidesAnUnknownPercentInstead() {
        #expect(downloadPercentLabel(42) == "Downloading 42%")
        #expect(downloadPercentLabel(unknownDownloadPercent) == "Downloading")
    }

    @Test func runtimeStateAndPhaseLabelsAgreeOnUnknownPercent() {
        #expect(RuntimeState.downloading(60).label == "Downloading 60%")
        #expect(RuntimeState.downloading(unknownDownloadPercent).label == "Downloading")
        #expect(RuntimePhase.downloading(60).label == "Downloading 60%")
        #expect(RuntimePhase.downloading(unknownDownloadPercent).label == "Downloading")
    }

    @Test func startupStepProgressIsMonotonicAndOnlyCoversStartupPhases() {
        let steps: [RuntimePhase] = [.preflight, .launching, .verifying, .warming, .ready]
        let progress = steps.compactMap(\.stepProgress)
        #expect(progress.count == steps.count)
        #expect(progress == progress.sorted())
        #expect(progress.last == 1.0)
        for phase: RuntimePhase in [.idle, .downloading(10), .generating, .recovering(attempt: 1), .failed] {
            #expect(phase.stepProgress == nil)
        }
    }
}
