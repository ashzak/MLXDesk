import Foundation

actor ModelCatalogService {
    /// `llmfit fit` takes real wall-clock time (it measures GPU/unified-memory
    /// headroom live). Running `Process.run/waitUntilExit` directly in this method
    /// would block the actor's serial executor for that whole duration -- harmless
    /// today since nothing else calls into this actor concurrently, but a trap for
    /// whoever adds a second caller later. `Task.detached` moves the blocking work
    /// onto the cooperative thread pool; this method just awaits its result, so the
    /// actor stays free the whole time.
    func load() async throws -> ModelCatalogSnapshot {
        let data = try await runLLMFit(["fit", "--json", "--no-dashboard"])
        let response = try JSONDecoder().decode(LLMFitResponse.self, from: data)
        let models = response.models
            .filter { $0.isMLXRepository && $0.fitLevel != "Too Tight" }
            .sorted { $0.score > $1.score }
            .map(\.appModel)
        return ModelCatalogSnapshot(hardware: response.system, models: models)
    }

    /// The bundled engine's own version (e.g. "1.1.9"), or `nil` if it can't be
    /// determined. There is no version check anywhere in this app -- an old bundled
    /// binary still decodes and runs fine (llmfit documents its `fit --json` shape
    /// as a stable contract for tool integrations like this one) -- so this exists
    /// purely to make that fact *visible* instead of invisible: it's threaded into
    /// the hardware summary and both diagnostic exports so a stale bundled engine
    /// shows up in a bug report instead of silently producing dated recommendations.
    func engineVersion() async -> String? {
        guard let data = try? await runLLMFit(["--version"]),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        // Output is "llmfit 1.1.9" -- keep just the version if that shape holds,
        // otherwise fall back to the raw string rather than fail silently.
        return text.split(separator: " ").last.map(String.init) ?? text
    }

    /// Refreshes llmfit's own local model cache from Hugging Face's trending/
    /// top-downloaded model lists, independent of this binary's version -- so a
    /// user isn't stuck with whatever models were embedded the day the app was
    /// built. The one network call this app makes that isn't a model download
    /// itself, so it only ever runs when a user explicitly asks for it (never on
    /// an automatic catalog load). Returns llmfit's own human-readable summary of
    /// what changed; `update --json` does not currently emit structured JSON on
    /// this llmfit version, so the raw text is the most honest thing to show.
    func updateModelDatabase() async throws -> String {
        let data = try await runLLMFit(["update", "--json"])
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false ? text : nil) ?? "Model database update finished."
    }

    private func runLLMFit(_ arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { () throws -> Data in
            guard let executable = Self.llmfitExecutable() else { throw CatalogError.llmfitMissing }
            let process = Process(); let output = Pipe(); let errors = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unknown llmfit error"
                throw CatalogError.llmfitFailed(message)
            }
            return data
        }.value
    }

    private static func llmfitExecutable() -> URL? {
        if let bundled = Bundle.main.url(forResource: "llmfit", withExtension: nil) { return bundled }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().appending(path: "llmfit/target/release/llmfit")
        return FileManager.default.isExecutableFile(atPath: development.path) ? development : nil
    }
}

enum CatalogError: LocalizedError {
    case llmfitMissing, llmfitFailed(String)
    var errorDescription: String? {
        switch self {
        case .llmfitMissing: "The bundled hardware compatibility engine is missing."
        case .llmfitFailed(let message): "llmfit reported an error: \(message)"
        }
    }
}
