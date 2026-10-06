import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

private final class NativeSessionBox: @unchecked Sendable {
    let session: ChatSession
    init(_ session: ChatSession) { self.session = session }
}

/// Holds the latest `fractionCompleted` reported by swift-huggingface's download
/// `Progress`, read from a `@Sendable` callback that can fire on any thread. A plain
/// actor rather than passing `Progress` itself across the boundary -- `Progress` is a
/// mutable reference type with no Sendable guarantee, whereas the `Double` snapshot
/// taken inside the callback is safe to hand off.
private actor DownloadProgressBox {
    private(set) var fractionCompleted: Double?
    func update(_ progress: Progress) {
        let fraction = progress.fractionCompleted
        if fraction.isFinite { fractionCompleted = fraction }
    }
}


actor MLXService {
    enum InjectedFault: Sendable { case startFailure, streamFailure, streamStall }
    private var process: Process?
    private var activeModelID: String?
    private var healthTask: Task<Void, Never>?
    private var logURL: URL?
    private(set) var isDemo: Bool
    private let injectedFault: InjectedFault?
    private var nativeContainer: ModelContainer?
    private var nativeSession: ChatSession?
    private var usesNativeRuntime: Bool {
        !isDemo && ProcessInfo.processInfo.environment["MLX_DESK_USE_LEGACY_SERVER"] != "1"
    }
    private let port = 51_888

    init(isDemo: Bool = ProcessInfo.processInfo.environment["MLX_DESK_UI_TESTING"] == "1", injectedFault: InjectedFault? = nil) {
        self.isDemo = isDemo
        self.injectedFault = injectedFault
    }

    func runtimeAvailable() async -> Bool {
        if isDemo { return true }
        if usesNativeRuntime { return true }
        return executable(named: "mlx_lm.server") != nil
    }

    func modelIsDownloaded(_ model: MLXModel) -> Bool {
        if model.isLocal { return true }
        return localSnapshot(for: model.repository) != nil
    }

    func cachedRevision(for repository: String) -> String? {
        let folder = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        let reference = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub/\(folder)/refs/main")
        return try? String(contentsOf: reference, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cachedModels() -> [CachedModelEntry] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return folders.filter { $0.lastPathComponent.hasPrefix("models--") }.compactMap { folder in
            let encoded = String(folder.lastPathComponent.dropFirst("models--".count))
            let repository = encoded.replacingOccurrences(of: "--", with: "/")
            guard repository.localizedCaseInsensitiveContains("mlx") || repository == activeModelID else { return nil }
            let values = try? folder.resourceValues(forKeys: [.contentModificationDateKey])
            return CachedModelEntry(repository: repository, bytes: directoryBytes(folder), incomplete: hasIncompleteFiles(for: repository), modifiedAt: values?.contentModificationDate)
        }.sorted { $0.bytes > $1.bytes }
    }

    func deleteCachedModel(repository: String) throws {
        if activeModelID == repository { throw ServiceError.modelInUse }
        let folder = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub/\(folder)")
        guard url.standardizedFileURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub/models--").path) else {
            throw ServiceError.invalidCachePath
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func verifyCachedModel(repository: String) throws { try validateCachedSnapshot(for: repository) }
    func cacheURL(repository: String) -> URL {
        let folder = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub/\(folder)")
    }

    func preflight(model: MLXModel) throws -> PreflightReport {
        #if !arch(arm64)
        throw PreflightError.unsupportedProcessor
        #endif
        if let directory = model.localDirectoryURL {
            try ResourcePreflightValidator.validateSnapshot(at: directory)
            let physical = ProcessInfo.processInfo.physicalMemory
            var warnings: [String] = []
            if let estimated = estimatedMemoryBytes(model), UInt64(estimated) > physical * 8 / 10 {
                warnings.append("This model may use more than 80% of physical memory.")
            }
            return PreflightReport(modelID: model.repository, availableDiskBytes: 0, requiredDiskBytes: 0,
                                   physicalMemoryBytes: physical, modelAlreadyDownloaded: true, warnings: warnings)
        }
        let downloaded = modelIsDownloaded(model)
        if downloaded { try validateCachedSnapshot(for: model.repository) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let required = Int64(Double(model.downloadBytes) * 1.25)
        try ResourcePreflightValidator.requireDisk(available: available, required: required, alreadyDownloaded: downloaded)
        var warnings: [String] = []
        if hasIncompleteFiles(for: model.repository), cachedBytes(for: model.repository) > 0 {
            warnings.append("An incomplete download was found and will be resumed.")
        }
        let physical = ProcessInfo.processInfo.physicalMemory
        if let estimated = estimatedMemoryBytes(model), UInt64(estimated) > physical * 8 / 10 {
            warnings.append("This model may use more than 80% of physical memory.")
        }
        return PreflightReport(modelID: model.repository, availableDiskBytes: available, requiredDiskBytes: required,
                               physicalMemoryBytes: physical, modelAlreadyDownloaded: downloaded, warnings: warnings)
    }

    func healthCheck(includeReadiness: Bool) async -> RuntimeHealth {
        if usesNativeRuntime {
            let loaded = nativeContainer != nil
            return RuntimeHealth(processOwnedByApp: loaded, endpointResponding: loaded,
                                 generationReady: loaded, checkedAt: .now)
        }
        let live = await serverResponds()
        var ready = false
        if live && includeReadiness { ready = (try? await warmUp()) != nil }
        return RuntimeHealth(processOwnedByApp: process?.isRunning == true, endpointResponding: live,
                             generationReady: includeReadiness ? ready : live, checkedAt: .now)
    }

    func install() async throws {
        if isDemo || usesNativeRuntime { return }
        guard let uv = executable(named: "uv") else { throw ServiceError.installFailed }
        let task = Process(); task.executableURL = uv; task.arguments = ["tool", "install", "-U", "mlx-lm"]
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw ServiceError.installFailed }
    }

    func start(model: MLXModel, progress: @escaping @Sendable (RuntimeProgress) async -> Void = { _ in }) async throws {
        if injectedFault == .startFailure { throw ServiceError.faultInjected("Model launch failed during a reliability test.") }
        _ = try preflight(model: model)
        if isDemo {
            await progress(.init(phase: .downloading(42), detail: "Downloading model files", completedBytes: model.downloadBytes * 42 / 100, totalBytes: model.downloadBytes))
            try await Task.sleep(for: .milliseconds(250))
            await progress(.init(phase: .verifying, detail: "Verifying cached files"))
            try await Task.sleep(for: .milliseconds(250))
            await progress(.init(phase: .warming, detail: "Running readiness check"))
            try await Task.sleep(for: .milliseconds(500)); return
        }
        if usesNativeRuntime {
            await progress(.init(phase: .launching, detail: "Preparing the native MLX engine"))
            // A local import has no remote id to resolve -- `.directory` tells
            // ModelConfiguration's resolver (mlx-swift-lm/ModelFactory.resolve) to read
            // weights straight from this path, with no Downloader/HubClient involved at
            // all. Same `#huggingFaceLoadModelContainer` call below handles both cases;
            // it switches on `configuration.id` internally. `loadableDirectory` may
            // return a shim directory rather than `model.localDirectoryURL` itself --
            // see its doc comment.
            let configuration = try model.localDirectoryURL.map { ModelConfiguration(directory: try loadableDirectory(for: $0)) } ?? ModelConfiguration(id: model.repository)
            // An earlier version of this method polled the Hugging Face cache's blobs
            // directory instead of trusting swift-huggingface's own Progress (see below for
            // why that callback was distrusted). That polling approach is fundamentally
            // blind for the large weight shard(s): URLSession's download(for:delegate:)
            // buffers each transfer to a private system temp file and only moves it into
            // the visible cache directory once the WHOLE download finishes, so the reported
            // percent sat at 0% for the entire multi-GB transfer -- confirmed live by
            // watching both the cache directory (flat) and the actual growing
            // CFNetworkDownload_*.tmp temp file (climbing in lockstep with real network
            // throughput) side by side during a fresh download.
            //
            // The Progress callback itself was previously found to freeze partway through
            // large concurrent downloads (reported progress pinned at a fixed byte count
            // while real data kept arriving) -- a suspected upstream bug in how the
            // library's task-group downloader wires concurrent shards' child Progress into
            // the parent. That may or may not still reproduce on the currently pinned
            // version, but either way there is no ground truth available from outside the
            // library that's cheaper than this: use the real Progress as the primary
            // signal, and if it stops advancing for a few seconds before reaching 100%,
            // fall back to an indeterminate spinner (unknownDownloadPercent) rather than
            // showing a specific percentage that has stopped meaning anything -- an honest
            // "still working" beats a number that looks stuck twice over.
            let progressBox = DownloadProgressBox()
            let downloadWatchTask = Task.detached {
                var bestFraction = 0.0
                var lastAdvance = ContinuousClock.now
                while !Task.isCancelled {
                    if let fraction = await progressBox.fractionCompleted {
                        if fraction > bestFraction { bestFraction = fraction; lastAdvance = .now }
                        let stalled = lastAdvance.duration(to: .now) > .seconds(5) && bestFraction < 1
                        if stalled {
                            // Once the reported fraction has stopped advancing, its last
                            // value is known-unreliable (see above) -- showing "11.5 MB of
                            // 5 GB" forever would flatly contradict gigabytes of real
                            // traffic still landing on disk. Drop the byte counts along
                            // with the percentage rather than keep asserting a specific,
                            // now-false number.
                            await progress(.init(phase: .downloading(unknownDownloadPercent),
                                                 detail: "Downloading native MLX model files -- large models can take a while"))
                        } else {
                            let percent = min(99, max(0, Int(bestFraction * 100)))
                            await progress(.init(phase: .downloading(percent), detail: "Downloading native MLX model files",
                                                 completedBytes: Int64(bestFraction * Double(model.downloadBytes)), totalBytes: model.downloadBytes))
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { downloadWatchTask.cancel() }
            // Must be the explicit `progressHandler:` label, NOT a trailing closure: mlx-swift-lm's
            // LoadContainerMacro expansion (Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift)
            // finds the closure to splice in by searching the macro call's argument list for a
            // label matching "progressHandler" -- a trailing closure carries no such label in that
            // list, so the macro silently falls back to a no-op `{ _ in }` and any closure passed
            // that way is never invoked at all.
            let container = try await #huggingFaceLoadModelContainer(
                configuration: configuration,
                progressHandler: { p in Task { await progressBox.update(p) } }
            )
            try Task.checkCancellation()
            nativeContainer = container
            nativeSession = nil
            activeModelID = model.repository
            await progress(.init(phase: .verifying, detail: "Model loaded by native MLX"))
            await progress(.init(phase: .warming, detail: "Native engine is ready"))
            return
        }
        if await serverResponds() {
            if process != nil, activeModelID == model.repository {
                for _ in 0..<3600 {
                    if !hasIncompleteFiles(for: model.repository) {
                        do {
                            await progress(.init(phase: .warming, detail: "Checking the existing model runtime"))
                            try await warmUp()
                            try validateModelDiagnostics()
                            return
                        } catch ServiceError.incompatibleTokenizer {
                            throw ServiceError.incompatibleTokenizer
                        } catch {
                            await stop()
                            break
                        }
                    }
                    let percent = downloadPercent(for: model)
                    await progress(.init(phase: .downloading(percent), detail: "Downloading model files", completedBytes: cachedBytes(for: model.repository), totalBytes: model.downloadBytes))
                    try await Task.sleep(for: .seconds(1))
                }
            } else {
                try terminateStaleServer()
                try await Task.sleep(for: .seconds(1))
            }
        }
        await stop()
        await progress(.init(phase: .launching, detail: "Starting the local MLX runtime"))
        guard let server = executable(named: "mlx_lm.server") else { throw ServiceError.installFailed }
        let task = Process(); task.executableURL = server
        task.arguments = ["--model", model.localDirectoryPath ?? localSnapshot(for: model.repository)?.path ?? model.repository, "--port", String(port)]
        let logs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MLXDesk/mlx-server.log")
        try FileManager.default.createDirectory(at: logs.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logs.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logs); task.standardOutput = logHandle; task.standardError = logHandle; logURL = logs
        try task.run(); process = task; activeModelID = model.repository
        for _ in 0..<3600 {
            try Task.checkCancellation()
            if await serverResponds(), !hasIncompleteFiles(for: model.repository) {
                await progress(.init(phase: .verifying, detail: "Verifying model compatibility"))
                try validateModelDiagnostics()
                await progress(.init(phase: .warming, detail: "Running one-token readiness check"))
                try await warmUp()
                try validateModelDiagnostics()
                return
            }
            if !task.isRunning { throw ServiceError.serverStopped(diagnostics()) }
            let percent = downloadPercent(for: model)
            await progress(.init(phase: .downloading(percent), detail: "Downloading model files", completedBytes: cachedBytes(for: model.repository), totalBytes: model.downloadBytes))
            try await Task.sleep(for: .seconds(1))
        }
        throw ServiceError.timedOut(diagnostics())
    }

    func stop() async {
        healthTask?.cancel(); healthTask = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; activeModelID = nil
        nativeSession = nil; nativeContainer = nil
    }

    func stream(
        messages: [ChatMessage], settings: GenerationSettings, workspaceURL: URL? = nil,
        onProposeEdit: @escaping @Sendable (PendingEdit) async -> Void = { _ in },
        onToolActivity: @escaping @Sendable (String?) async -> Void = { _ in }
    ) -> AsyncThrowingStream<String, Error> {
        if isDemo {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    if self.injectedFault == .streamStall {
                        try? await Task.sleep(for: .seconds(3_600))
                        continuation.finish()
                        return
                    }
                    let answer = "Here’s a clean approach:\n\n```swift\nfunc greet(_ name: String) -> String {\n    \"Hello, \\(name)!\"\n}\n```\n\nThis keeps the function pure and easy to test."
                    for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
                        if Task.isCancelled { break }
                        continuation.yield(String(word) + " ")
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    if self.injectedFault == .streamFailure {
                        continuation.finish(throwing: ServiceError.faultInjected("Generation stopped during a reliability test."))
                        return
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        if usesNativeRuntime {
            guard let nativeContainer else {
                return AsyncThrowingStream { $0.finish(throwing: ServiceError.badResponse) }
            }
            let transcript = messages.map { "\($0.role.rawValue.capitalized): \($0.content)" }.joined(separator: "\n\n")
            // Workspace tools are only registered when a folder is open: with no
            // workspaceURL, tools/toolDispatch stay nil and this is byte-for-byte
            // the same ChatSession construction as before workspace support existed
            // -- zero behavior change for plain chat use.
            var toolSet: [ToolSpec]?
            var toolDispatch: (@Sendable (ToolCall) async throws -> String)?
            if let workspaceURL {
                let built = WorkspaceTools.makeToolSet(root: workspaceURL, onPropose: onProposeEdit, onActivity: onToolActivity)
                toolSet = built.tools
                toolDispatch = built.dispatch
            }
            let session = ChatSession(
                nativeContainer,
                instructions: settings.systemPrompt,
                generateParameters: .init(maxTokens: settings.maxTokens, temperature: Float(settings.temperature)),
                // Only set when disabled: omitting the key entirely for the
                // enabled case keeps this a no-op for every template that
                // doesn't define `enable_thinking` at all, rather than handing
                // it a key it has to know to ignore.
                additionalContext: settings.thinkingEnabled ? nil : ["enable_thinking": false],
                tools: toolSet,
                toolDispatch: toolDispatch
            )
            nativeSession = session
            let sessionBox = NativeSessionBox(session)
            return AsyncThrowingStream { continuation in
                // .detached is load-bearing: a plain Task{} here inherits this actor's
                // isolation, so every resumption of the token-generation loop below (every
                // few tens of milliseconds, for the life of the whole response) has to
                // re-acquire MLXService's serial executor. That pins the actor to this one
                // generation for its entire duration -- any other actor call (stop(), the
                // next message's stream(), a model switch) silently queues behind it and
                // never runs until this response finishes on its own, which is exactly what
                // made Stop look like it did nothing and the rest of the app look frozen
                // while a response was streaming. NativeSessionBox exists precisely to make
                // the session Sendable across this boundary, so detaching is what it was
                // built for.
                let task = Task.detached {
                    do {
                        for try await chunk in sessionBox.session.streamResponse(to: transcript) {
                            try Task.checkCancellation()
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        let requestedModel = activeModelID
        let port = port
        return AsyncThrowingStream { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration)
            // .detached for the same reason as the native runtime path above: this must
            // not sit on MLXService's serial executor for the whole response, or it blocks
            // every other actor call (Stop, the next message, a model switch) until the
            // HTTP stream finishes on its own.
            let task = Task.detached {
                do {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                    request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let system = ChatMessage(role: .system, content: settings.systemPrompt)
                    let payload: [String: Any] = [
                        "model": requestedModel ?? "",
                        "messages": ([system] + messages).map { ["role": $0.role.rawValue, "content": $0.content] },
                        "temperature": settings.temperature, "max_tokens": settings.maxTokens, "stream": true
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.badResponse }
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        let raw = String(line.dropFirst(6)); if raw == "[DONE]" { break }
                        if let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = object["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any], let text = delta["content"] as? String { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
        }
    }

    private func serverResponds() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
        var request = URLRequest(url: url); request.timeoutInterval = 1
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    private func warmUp() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": activeModelID ?? "",
            "messages": [["role": "user", "content": "Reply OK"]],
            "max_tokens": 1, "temperature": 0, "stream": false
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.badResponse }
    }

    private func validateModelDiagnostics() throws {
        let log = diagnostics().lowercased()
        if log.contains("incorrect regex pattern") && log.contains("incorrect tokenization") {
            throw ServiceError.incompatibleTokenizer
        }
    }

    private func terminateStaleServer() throws {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe(); lsof.standardOutput = pipe; lsof.standardError = Pipe()
        try lsof.run(); lsof.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let pid = output.split(whereSeparator: \.isNewline).compactMap({ Int32($0) }).first else {
            throw ServiceError.staleServerCouldNotStop
        }

        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let commandPipe = Pipe(); ps.standardOutput = commandPipe; ps.standardError = Pipe()
        try ps.run(); ps.waitUntilExit()
        let command = String(data: commandPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard command.contains("mlx_lm.server"), command.contains("--port \(port)") else {
            throw ServiceError.staleServerCouldNotStop
        }

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/bin/kill")
        kill.arguments = ["-TERM", String(pid)]
        try kill.run(); kill.waitUntilExit()
        guard kill.terminationStatus == 0 else { throw ServiceError.staleServerCouldNotStop }
    }

    private func executable(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/\(name)", "\(home)/.local/bin/\(name)", "/usr/local/bin/\(name)"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    private func cachedBytes(for repository: String) -> Int64 {
        let folder = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub/\(folder)")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    private func directoryBytes(_ root: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        return files.reduce(into: Int64(0)) { total, item in
            guard let url = item as? URL else { return }
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func downloadPercent(for model: MLXModel) -> Int {
        // downloadSizeIsEstimated means downloadBytes is just what's already cached for
        // a resumed-but-incomplete model with no catalog entry, not its true total --
        // dividing by it would always read back as ~100% no matter how much is left.
        guard !model.downloadSizeIsEstimated, model.downloadBytes > 0 else { return unknownDownloadPercent }
        return min(99, max(0, Int(Double(cachedBytes(for: model.repository)) / Double(model.downloadBytes) * 100)))
    }

    private func hasIncompleteFiles(for repository: String) -> Bool {
        let folder = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        let blobs = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub/\(folder)/blobs")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: blobs.path) else { return true }
        return names.contains { $0.hasSuffix(".incomplete") }
    }

    private func localSnapshot(for repository: String) -> URL? {
        let folder = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub/\(folder)")
        guard let revision = try? String(contentsOf: root.appending(path: "refs/main"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !revision.isEmpty else { return nil }
        let snapshot = root.appending(path: "snapshots/\(revision)")
        guard !hasIncompleteFiles(for: repository), ResourcePreflightValidator.isComplete(at: snapshot) else { return nil }
        return snapshot
    }

    /// swift-transformers' tokenizer loader (vendored at
    /// .build/checkouts/swift-transformers/Sources/Tokenizers/Tokenizer.swift,
    /// `TokenizerModel.knownTokenizers`) only recognizes a fixed, hardcoded list of
    /// `tokenizer_class` values and -- called with its default `strict: true` by the
    /// `#huggingFaceLoadModelContainer` macro this app uses -- throws
    /// `unsupportedTokenizer` for anything outside it, rather than falling back to
    /// plain BPE the way it would under `strict: false`. A freshly-converted model
    /// can easily carry a `tokenizer_class` newer than this pinned dependency knows
    /// about (confirmed live: "Qwen3_5Tokenizer" from an `mlx_lm.convert` output,
    /// rejected even though it's the exact same BPE format as the already-recognized
    /// "Qwen2Tokenizer" one line above it in that table) -- the underlying
    /// tokenizer.json vocab/merges are unaffected by the class name either way.
    ///
    /// Patching the vendored checkout directly was ruled out: `swift package
    /// update`/a clean resolve would silently discard it. Instead, for an
    /// unrecognized class, this builds (or reuses) a same-named sibling directory
    /// under Application Support that symlinks every file from the original model
    /// folder except tokenizer_config.json, which gets a byte-identical copy with
    /// only `tokenizer_class` rewritten to "PreTrainedTokenizer" -- a name the table
    /// does map to BPETokenizer, i.e. exactly the fallback `strict: false` would have
    /// chosen anyway. The user's own folder is never written to. Returns the
    /// original directory unchanged (no shim, no filesystem writes at all) whenever
    /// the class is already recognized, which is the common case for anything
    /// downloaded from mlx-community.
    private func loadableDirectory(for original: URL) throws -> URL {
        let configURL = original.appending(path: "tokenizer_config.json")
        guard let data = try? Data(contentsOf: configURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenizerClass = parsed["tokenizer_class"] as? String else { return original }
        let knownTokenizerClasses: Set<String> = [
            "BertTokenizer", "CodeGenTokenizer", "CodeLlamaTokenizer", "CohereTokenizer",
            "DistilbertTokenizer", "DistilBertTokenizer", "FalconTokenizer", "GemmaTokenizer",
            "GPT2Tokenizer", "LlamaTokenizer", "RobertaTokenizer", "T5Tokenizer",
            "TokenizersBackend", "PreTrainedTokenizer", "Qwen2Tokenizer", "WhisperTokenizer",
            "XLMRobertaTokenizer", "Xlm-RobertaTokenizer",
        ]
        guard !knownTokenizerClasses.contains(tokenizerClass.replacingOccurrences(of: "Fast", with: "")) else { return original }

        let manager = FileManager.default
        let sanitizedName = original.path.replacingOccurrences(of: "/", with: "_")
        let shimDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MLXDesk/LocalModelShims/\(sanitizedName)")
        try? manager.removeItem(at: shimDirectory)
        try manager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        for file in (try? manager.contentsOfDirectory(at: original, includingPropertiesForKeys: nil)) ?? [] {
            guard file.lastPathComponent != "tokenizer_config.json" else { continue }
            try? manager.createSymbolicLink(at: shimDirectory.appending(path: file.lastPathComponent), withDestinationURL: file)
        }
        var patched = parsed
        patched["tokenizer_class"] = "PreTrainedTokenizer"
        let patchedData = try JSONSerialization.data(withJSONObject: patched, options: [.prettyPrinted])
        try patchedData.write(to: shimDirectory.appending(path: "tokenizer_config.json"))
        return shimDirectory
    }

    private func validateCachedSnapshot(for repository: String) throws {
        guard let snapshot = localSnapshot(for: repository) else { throw PreflightError.invalidModelCache("No complete snapshot was found.") }
        try ResourcePreflightValidator.validateSnapshot(at: snapshot)
    }

    private func estimatedMemoryBytes(_ model: MLXModel) -> Int64? {
        guard let match = model.memory.firstMatch(of: /([0-9]+(?:\.[0-9]+)?)/), let value = Double(match.1) else { return nil }
        return Int64(value * 1_000_000_000)
    }

    private func diagnostics() -> String {
        guard let logURL, let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "No diagnostic details were written." }
        return String(text.suffix(1200))
    }
}

enum ServiceError: LocalizedError {
    case installFailed, serverStopped(String), timedOut(String), badResponse, staleServerCouldNotStop, incompatibleTokenizer, faultInjected(String), modelInUse, invalidCachePath
    var errorDescription: String? {
        switch self {
        case .installFailed: "MLX-LM couldn’t be installed. Check that uv is available."
        case .serverStopped(let details): "The model process stopped unexpectedly.\n\n\(details)"
        case .timedOut(let details): "The model was still unavailable after one hour.\n\n\(details)"
        case .badResponse: "The model server returned an unexpected response."
        case .staleServerCouldNotStop: "The existing MLX server is not responding and couldn’t be restarted safely. Quit its terminal process, then try again."
        case .incompatibleTokenizer: "This model reported an incompatible tokenizer and may produce corrupted or hallucinated answers. Choose a verified mlx-community model instead."
        case .faultInjected(let message): message
        case .modelInUse: "Stop or switch away from this model before deleting it."
        case .invalidCachePath: "The model cache path was invalid and was not changed."
        }
    }
}
