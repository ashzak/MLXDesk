import Foundation

struct Conversation: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var updatedAt = Date()
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, system }
    var id = UUID()
    var role: Role
    var content: String
    var createdAt = Date()
}

/// A file staged in the composer, waiting to be folded into the next message's
/// text when it is sent. Not persisted on its own -- MLXService only ever sends
/// plain-text message content (see MLXService.stream), so a file's content is
/// inlined as a fenced code block rather than carried as a separate attachment
/// type. Transient composer state only, so this intentionally isn't Codable.
struct ComposerAttachment: Identifiable, Hashable, Sendable {
    let id = UUID()
    let filename: String
    let text: String
    let truncated: Bool
}

struct MLXModel: Identifiable, Codable, Hashable, Sendable {
    var id: String { repository }
    let repository: String
    let displayName: String
    let detail: String
    let size: String
    let memory: String
    let downloadBytes: Int64
    let recommended: Bool
    var fitLevel: String? = nil
    var parameters: String? = nil
    var estimatedTPS: Double? = nil
    var score: Double? = nil
    /// True when `downloadBytes` is a stand-in (the bytes already cached for an
    /// incomplete download, not the model's real total size) rather than a value
    /// known from the catalog. Download-percent math must not trust it as a
    /// denominator -- doing so makes a still-incomplete resume read as ~100% done.
    var downloadSizeIsEstimated: Bool = false
    /// Set only for models imported from a folder on disk (see `LocalModelStore`).
    /// When present, this is authoritative over `repository`-based Hugging Face
    /// cache/download logic everywhere in MLXService -- there is no remote source
    /// to check or fetch, the weights are already sitting at this path.
    var localDirectoryPath: String? = nil

    var isLocal: Bool { localDirectoryPath != nil }
    var localDirectoryURL: URL? { localDirectoryPath.map { URL(fileURLWithPath: $0) } }

    var bestFor: String {
        let name = "\(repository) \(displayName)".lowercased()
        if name.contains("embed") { return "Semantic search, retrieval, and document similarity" }
        if name.contains("vision") || name.contains("-vl") || name.contains("vl-") { return "Understanding images, screenshots, and documents" }
        if name.contains("coder") || name.contains("code-") || name.contains("code_") { return "Writing code, debugging, and repository work" }
        if name.contains("math") { return "Mathematics, calculation, and structured problem solving" }
        if name.contains("reason") || name.contains("deepseek-r1") || name.contains("-r1-") { return "Multi-step reasoning, planning, and analysis" }
        if name.contains("translate") || name.contains("translation") { return "Translation and multilingual writing" }
        if name.contains("tool") || name.contains("function") { return "Tool use and structured function calling" }
        if isLightweight { return "Fast chat, summarization, and lightweight everyday tasks" }
        return "General chat, writing, summarization, and instruction following"
    }

    var bestForIcon: String {
        let use = bestFor
        if use.hasPrefix("Semantic") { return "magnifyingglass" }
        if use.hasPrefix("Understanding") { return "photo" }
        if use.hasPrefix("Writing code") { return "chevron.left.forwardslash.chevron.right" }
        if use.hasPrefix("Mathematics") { return "function" }
        if use.hasPrefix("Multi-step") { return "brain.head.profile" }
        if use.hasPrefix("Translation") { return "character.bubble" }
        if use.hasPrefix("Tool use") { return "wrench.and.screwdriver" }
        if use.hasPrefix("Fast chat") { return "bolt.fill" }
        return "text.bubble"
    }

    private var isLightweight: Bool {
        let value = (parameters ?? displayName).lowercased()
        let pattern = #"(?:^|[^0-9.])(0\.[0-9]+|[1-3](?:\.[0-9]+)?)\s*b(?:[^a-z]|$)"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    var trustLevel: ModelTrustLevel {
        if isLocal { return .localImport }
        return repository.lowercased().hasPrefix("mlx-community/") ? .verifiedConversion : .community
    }

    /// Builds an `MLXModel` entry for a folder of MLX weights already on disk (e.g.
    /// produced by `mlx_lm.convert`), after validating it looks loadable. The
    /// `repository` is a synthetic, stable id (`local/<folder name>`) used only as a
    /// dictionary key for compatibility/quarantine tracking and the model picker --
    /// MLXService never treats it as a Hugging Face id because `localDirectoryPath`
    /// takes priority everywhere that matters (see MLXService.start).
    static func local(directory: URL) throws -> MLXModel {
        try ResourcePreflightValidator.validateSnapshot(at: directory)
        let name = directory.lastPathComponent
        let bytes = Self.directorySize(directory)
        let gb = Double(bytes) / 1_000_000_000
        return MLXModel(
            repository: "local/\(name)",
            displayName: name,
            detail: "Imported from \(directory.path)",
            size: String(format: "~%.1f GB", gb),
            // Unified memory while running a local weight file tends to run somewhat
            // above the on-disk size (activations, KV cache) -- 1.15x is a rough same
            // margin as `FitModel.appModel` uses between its reported size and memory.
            memory: String(format: "~%.1f GB", gb * 1.15),
            downloadBytes: bytes, recommended: false,
            localDirectoryPath: directory.path
        )
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        return files.reduce(into: Int64(0)) { total, item in
            guard let fileURL = item as? URL else { return }
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static let curated: [MLXModel] = [
        .init(repository: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", displayName: "Qwen3 Coder 30B", detail: "Best balance for this M1 Max", size: "~19 GB", memory: "~22 GB", downloadBytes: 19_000_000_000, recommended: true),
        .init(repository: "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit", displayName: "Qwen2.5 Coder 14B", detail: "Faster, with more room for other apps", size: "~9 GB", memory: "~12 GB", downloadBytes: 9_000_000_000, recommended: false),
        .init(repository: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", displayName: "Qwen2.5 Coder 7B", detail: "Fastest for quick edits", size: "~5 GB", memory: "~8 GB", downloadBytes: 5_000_000_000, recommended: false)
    ]
}

enum ModelTrustLevel: String, Codable, Sendable {
    case verifiedConversion = "Verified conversion"
    case community = "Community — unverified"
    case localImport = "Local import"

    var isTrusted: Bool { self == .verifiedConversion || self == .localImport }
}

struct LLMFitResponse: Decodable, Sendable {
    let system: FitSystem
    let models: [FitModel]
}

struct FitSystem: Codable, Equatable, Sendable {
    let cpuName: String
    let cpuCores: Int
    let totalRAMGB: Double
    let availableRAMGB: Double
    let gpuName: String
    let gpuAvailableGB: Double
    let backend: String

    enum CodingKeys: String, CodingKey {
        case cpuName = "cpu_name", cpuCores = "cpu_cores"
        case totalRAMGB = "total_ram_gb", availableRAMGB = "available_ram_gb"
        case gpuName = "gpu_name", gpuAvailableGB = "gpu_available_gb", backend
    }
}

struct ModelCatalogSnapshot: Sendable {
    let hardware: FitSystem
    let models: [MLXModel]
}

struct FitModel: Decodable, Sendable {
    let name: String
    let provider: String
    let parameterCount: String
    let fitLevel: String
    let estimatedTPS: Double
    let memoryRequiredGB: Double
    let bestQuant: String
    let runtime: String
    let score: Double

    enum CodingKeys: String, CodingKey {
        case name, provider, score, runtime
        case parameterCount = "parameter_count"
        case fitLevel = "fit_level"
        case estimatedTPS = "estimated_tps"
        case memoryRequiredGB = "memory_required_gb"
        case bestQuant = "best_quant"
    }

    var isMLXRepository: Bool {
        let value = "\(provider)/\(name)".lowercased()
        return runtime == "MLX" && (value.contains("mlx") || provider.lowercased() == "lmstudio-community")
    }

    var appModel: MLXModel {
        // bestQuant is llmfit's hardware recommendation ("an 8-bit build would run just as
        // well on this Mac"), not a property of this already-fixed repository -- e.g. it
        // reads "mlx-8bit" on the literal .../Qwen3.5-9B-4bit repo, because that's what
        // llmfit would suggest for a *different* build of this model, not what this one
        // actually is. Showing it next to the repo's own (already-baked-in) quantization
        // read as a flat contradiction: "Qwen3.5-9B-4bit" picked, "mlx-8bit" shown right
        // under it. Left out of detail; the repository name is the actual quantization.
        MLXModel(repository: name, displayName: name.split(separator: "/").last.map(String.init) ?? name,
                 detail: "\(fitLevel) fit · \(parameterCount)",
                 size: String(format: "~%.1f GB", memoryRequiredGB * 0.82),
                 memory: String(format: "~%.1f GB", memoryRequiredGB),
                 downloadBytes: Int64(memoryRequiredGB * 0.82 * 1_000_000_000), recommended: false,
                 fitLevel: fitLevel, parameters: parameterCount, estimatedTPS: estimatedTPS, score: score)
    }
}

struct GenerationSettings: Codable, Equatable, Sendable {
    var temperature = 0.2
    var maxTokens = 2048
    var contextLength = 32768
    var systemPrompt = "You are an expert coding assistant. Be concise, explain tradeoffs, and return complete code when asked."
}

/// A download percent of `unknownDownloadPercent` means the total size behind it is
/// only an estimate (e.g. resuming a cached model llmfit's catalog has no entry for),
/// so it must never be rendered as a real percentage -- see `MLXModel.downloadSizeIsEstimated`.
let unknownDownloadPercent = -1

func downloadPercentLabel(_ percent: Int) -> String {
    percent >= 0 ? "Downloading \(percent)%" : "Downloading"
}

enum RuntimeState: Equatable, Sendable {
    case checking, unavailable, ready, downloading(Int), starting, running, failed(String)
    var label: String {
        switch self {
        case .checking: "Checking MLX"
        case .unavailable: "Setup required"
        case .downloading(let percent): downloadPercentLabel(percent)
        case .ready: "Ready"
        case .starting: "Loading model"
        case .running: "Model online"
        case .failed: "Needs attention"
        }
    }
}
