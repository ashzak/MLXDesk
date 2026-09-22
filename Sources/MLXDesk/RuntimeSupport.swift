import Foundation
import OSLog

enum RuntimePhase: Equatable, Sendable {
    case idle
    case preflight
    case downloading(Int)
    case verifying
    case launching
    case warming
    case ready
    case generating
    case recovering(attempt: Int)
    case failed

    var label: String {
        switch self {
        case .idle: "Idle"
        case .preflight: "Checking this Mac"
        case .downloading(let percent): downloadPercentLabel(percent)
        case .verifying: "Verifying model"
        case .launching: "Starting runtime"
        case .warming: "Warming model"
        case .ready: "Ready"
        case .generating: "Generating"
        case .recovering(let attempt): "Recovering (attempt \(attempt))"
        case .failed: "Needs attention"
        }
    }

    /// A deterministic 0...1 position within the model-startup pipeline (preflight ->
    /// launching -> verifying -> warming -> ready), for phases that have no byte count
    /// to compute a percent from. `nil` for phases the startup indicator doesn't cover
    /// (e.g. `.downloading`, which already has its own byte-based percent).
    var stepProgress: Double? {
        switch self {
        case .preflight: 0.15
        case .launching: 0.45
        case .verifying: 0.7
        case .warming: 0.9
        case .ready: 1.0
        case .idle, .downloading, .generating, .recovering, .failed: nil
        }
    }
}

struct RuntimeProgress: Sendable, Equatable {
    let phase: RuntimePhase
    let detail: String
    let completedBytes: Int64?
    let totalBytes: Int64?

    init(phase: RuntimePhase, detail: String, completedBytes: Int64? = nil, totalBytes: Int64? = nil) {
        self.phase = phase; self.detail = detail; self.completedBytes = completedBytes; self.totalBytes = totalBytes
    }
}

struct ModelCompatibilityRecord: Codable, Sendable, Equatable {
    let modelID: String
    var revision: String?
    var failureCount: Int
    var lastFailure: String?
    var quarantined: Bool
    var updatedAt: Date
}

actor ModelCompatibilityStore {
    private var records: [String: ModelCompatibilityRecord] = [:]
    private let fileURL: URL?

    init(fileURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "MLXDesk/model-compatibility.json")) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([String: ModelCompatibilityRecord].self, from: data) {
            records = decoded
        }
    }

    func record(for modelID: String) -> ModelCompatibilityRecord? { records[modelID] }

    func recordSuccess(modelID: String, revision: String?) {
        records[modelID] = .init(modelID: modelID, revision: revision, failureCount: 0, lastFailure: nil, quarantined: false, updatedAt: .now)
        persist()
    }

    @discardableResult func recordCompatibilityFailure(modelID: String, revision: String?, reason: String) -> ModelCompatibilityRecord {
        var record = records[modelID] ?? .init(modelID: modelID, revision: revision, failureCount: 0, lastFailure: nil, quarantined: false, updatedAt: .now)
        if record.revision != revision { record.failureCount = 0; record.quarantined = false }
        record.revision = revision; record.failureCount += 1; record.lastFailure = reason
        record.quarantined = record.failureCount >= 2; record.updatedAt = .now
        records[modelID] = record; persist(); return record
    }

    func clear(modelID: String) { records.removeValue(forKey: modelID); persist() }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct RuntimeHealth: Sendable, Equatable, Codable {
    let processOwnedByApp: Bool
    let endpointResponding: Bool
    let generationReady: Bool
    let checkedAt: Date
}

struct PreflightReport: Sendable, Equatable, Codable {
    let modelID: String
    let availableDiskBytes: Int64
    let requiredDiskBytes: Int64
    let physicalMemoryBytes: UInt64
    let modelAlreadyDownloaded: Bool
    let warnings: [String]

    var isDiskSafe: Bool { modelAlreadyDownloaded || availableDiskBytes >= requiredDiskBytes }
}

struct DiagnosticEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: String
    let name: String
    let operationID: UUID?
    let modelID: String?
    let detail: String

    init(category: String, name: String, operationID: UUID? = nil, modelID: String? = nil, detail: String = "") {
        self.id = UUID(); self.timestamp = .now; self.category = category; self.name = name
        self.operationID = operationID; self.modelID = modelID; self.detail = detail
    }
}

actor DiagnosticsStore {
    static let shared = DiagnosticsStore()
    private let logger = Logger(subsystem: "dev.codex.MLXDesk", category: "runtime")
    private var events: [DiagnosticEvent] = []
    private let maximumEvents = 500

    func record(_ event: DiagnosticEvent) {
        events.append(event)
        if events.count > maximumEvents { events.removeFirst(events.count - maximumEvents) }
        logger.info("\(event.category, privacy: .public).\(event.name, privacy: .public) \(event.detail, privacy: .private(mask: .hash))")
    }

    func recentEvents() -> [DiagnosticEvent] { events }

    func export(model: MLXModel, runtime: RuntimeState, phase: RuntimePhase, preflight: PreflightReport?, modelCatalogEngineVersion: String?) throws -> Data {
        struct BundleReport: Codable {
            let generatedAt: Date
            let appVersion: String
            let osVersion: String
            let hardware: String
            let modelCatalogEngineVersion: String?
            let selectedModel: String
            let runtime: String
            let phase: String
            let preflight: PreflightReport?
            let events: [DiagnosticEvent]
            let privacy: String
        }
        let report = BundleReport(
            generatedAt: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardware: Self.hardwareSummary(),
            modelCatalogEngineVersion: modelCatalogEngineVersion,
            selectedModel: model.repository,
            runtime: runtime.label,
            phase: phase.label,
            preflight: preflight,
            events: events,
            privacy: "Prompts and model responses are excluded. Diagnostic details are locally generated."
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    private static func hardwareSummary() -> String {
        "\(ProcessInfo.processInfo.processorCount) cores, \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB memory"
    }
}

struct RestartCircuitBreaker: Sendable {
    private(set) var failures: [Date] = []
    let maximumFailures: Int
    let window: TimeInterval

    init(maximumFailures: Int = 2, window: TimeInterval = 300) {
        self.maximumFailures = maximumFailures; self.window = window
    }

    mutating func recordFailure(now: Date = .now) {
        failures = failures.filter { now.timeIntervalSince($0) <= window }
        failures.append(now)
    }

    mutating func reset() { failures.removeAll() }

    mutating func permitsAttempt(now: Date = .now) -> Bool {
        failures = failures.filter { now.timeIntervalSince($0) <= window }
        return failures.count < maximumFailures
    }
}

enum PreflightError: LocalizedError, Equatable {
    case unsupportedProcessor
    case insufficientDisk(required: Int64, available: Int64)
    case incompleteModelCache
    case invalidModelCache(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProcessor: "MLX Desk requires a Mac with Apple silicon."
        case .insufficientDisk(let required, let available):
            "Not enough free disk space. The model needs about \(Self.gb(required)) GB, but \(Self.gb(available)) GB is available."
        case .incompleteModelCache: "The cached model is incomplete. Remove the partial download or retry while online."
        case .invalidModelCache(let detail): "The downloaded model failed validation: \(detail)"
        }
    }

    private static func gb(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_000_000_000) }
}

enum ResourcePreflightValidator {
    static func requireDisk(available: Int64, required: Int64, alreadyDownloaded: Bool) throws {
        guard alreadyDownloaded || available >= required else {
            throw PreflightError.insufficientDisk(required: required, available: available)
        }
    }

    static func validateSnapshot(at snapshot: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: snapshot.appending(path: "config.json").path) else {
            throw PreflightError.invalidModelCache("config.json is missing.")
        }
        let tokenizerCandidates = ["tokenizer.json", "tokenizer.model", "tokenizer_config.json"]
        guard tokenizerCandidates.contains(where: { manager.fileExists(atPath: snapshot.appending(path: $0).path) }) else {
            throw PreflightError.invalidModelCache("Tokenizer files are missing.")
        }
        let files = (try? manager.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil)) ?? []
        guard files.contains(where: { $0.pathExtension == "safetensors" }) else {
            throw PreflightError.invalidModelCache("Model weight files are missing.")
        }
        if let missing = missingShards(in: snapshot), !missing.isEmpty {
            throw PreflightError.invalidModelCache(
                "\(missing.count) weight shard file(s) are missing (e.g. \(missing[0])) -- the download did not finish.")
        }
    }

    /// Non-throwing form for call sites that just need a yes/no (e.g. deciding whether to show
    /// "Downloaded" vs. offer to start a download), without needing to unwrap or discard an error.
    static func isComplete(at snapshot: URL) -> Bool {
        (try? validateSnapshot(at: snapshot)) != nil
    }

    /// For a multi-shard model, `model.safetensors.index.json`'s `weight_map` lists every shard
    /// filename the model actually needs. A download interrupted partway through can leave some
    /// shards present and others entirely absent, with no on-disk marker anywhere to say so: the
    /// native runtime's downloader moves each file into place only once it's fully written, so a
    /// missing shard looks identical to "still downloading" and identical to "nothing's wrong"
    /// from a plain directory listing -- confirmed live, where a model at ~7% of its real size,
    /// with zero incomplete-file markers, still read back as fully downloaded. Cross-checking
    /// against the index is the only way to tell "some safetensors files" from "all of them".
    /// Returns nil (not "no shards missing") when there's no index to check against, i.e. a
    /// single-file model, where "the one file is present" already fully answers completeness.
    private static func missingShards(in snapshot: URL) -> [String]? {
        let indexURL = snapshot.appending(path: "model.safetensors.index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String] else { return nil }
        let expectedShards = Set(weightMap.values)
        let manager = FileManager.default
        return expectedShards.filter { !manager.fileExists(atPath: snapshot.appending(path: $0).path) }.sorted()
    }
}
