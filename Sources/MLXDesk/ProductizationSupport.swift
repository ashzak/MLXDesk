import AppKit
import Foundation
import Observation
import Sparkle

enum L10n {
    static let storageTitle = localized("storage.title", fallback: "Model Storage")
    static let onboardingTitle = localized("onboarding.title", fallback: "Private AI, matched to this Mac")
    static let diagnosticsTitle = localized("diagnostics.title", fallback: "MLX Desk Diagnostics")

    private static func localized(_ key: String, fallback: String) -> String {
        Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
    }
}

struct CachedModelEntry: Identifiable, Sendable, Equatable {
    var id: String { repository }
    let repository: String
    let bytes: Int64
    let incomplete: Bool
    let modifiedAt: Date?
}

struct PerformanceSample: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let modelID: String
    let tokensPerSecond: Double
    let firstTokenSeconds: Double
}

actor PerformanceStore {
    private var samples: [PerformanceSample] = []
    private let fileURL: URL?

    init(fileURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "MLXDesk/performance.json")) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([PerformanceSample].self, from: data) { samples = saved }
    }

    func add(modelID: String, tokensPerSecond: Double, firstTokenSeconds: Double) {
        samples.append(.init(id: UUID(), timestamp: .now, modelID: modelID, tokensPerSecond: tokensPerSecond, firstTokenSeconds: firstTokenSeconds))
        if samples.count > 200 { samples.removeFirst(samples.count - 200) }
        persist()
    }

    func all() -> [PerformanceSample] { samples.reversed() }
    func clear() { samples.removeAll(); persist() }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(samples) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor @Observable
final class AppPreferences {
    private let defaults: UserDefaults
    var idleUnloadMinutes: Int { didSet { defaults.set(idleUnloadMinutes, forKey: "idleUnloadMinutes") } }
    var unloadOnLowPower: Bool { didSet { defaults.set(unloadOnLowPower, forKey: "unloadOnLowPower") } }
    var protectThermals: Bool { didSet { defaults.set(protectThermals, forKey: "protectThermals") } }
    var updateChannel: String { didSet { defaults.set(updateChannel, forKey: "updateChannel") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        idleUnloadMinutes = defaults.object(forKey: "idleUnloadMinutes") == nil ? 15 : defaults.integer(forKey: "idleUnloadMinutes")
        unloadOnLowPower = defaults.object(forKey: "unloadOnLowPower") == nil ? true : defaults.bool(forKey: "unloadOnLowPower")
        protectThermals = defaults.object(forKey: "protectThermals") == nil ? true : defaults.bool(forKey: "protectThermals")
        updateChannel = defaults.string(forKey: "updateChannel") ?? "Stable"
    }
}

/// Models imported from a local folder (see `MLXModel.local(directory:)`), persisted
/// across launches the same way everything else here is -- flat UserDefaults, no
/// migration story needed since this is a small, user-curated list.
@MainActor @Observable
final class LocalModelStore {
    private let defaults: UserDefaults
    private let key = "localModels"
    var models: [MLXModel] {
        didSet {
            guard let data = try? JSONEncoder().encode(models) else { return }
            defaults.set(data, forKey: key)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([MLXModel].self, from: data) {
            models = saved
        } else {
            models = []
        }
    }

    func add(_ model: MLXModel) {
        models.removeAll { $0.repository == model.repository }
        models.insert(model, at: 0)
    }

    func remove(_ model: MLXModel) {
        models.removeAll { $0.repository == model.repository }
    }
}

@MainActor
final class UpdateController {
    static let shared = UpdateController()
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    var isConfigured: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return feed.hasPrefix("https://") && !feed.contains("example.invalid") && !key.isEmpty
    }

    func startWhenConfigured() { if isConfigured { controller.startUpdater() } }
    func checkForUpdates() { if isConfigured { controller.checkForUpdates(nil) } }
}

enum OnboardingState {
    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingComplete") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingComplete") }
    }
}
