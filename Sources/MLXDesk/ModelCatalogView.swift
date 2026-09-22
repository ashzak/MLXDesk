import SwiftUI

struct ModelCatalogView: View {
    enum FitFilter: String, CaseIterable, Identifiable {
        case all = "All", perfect = "Perfect", good = "Good", marginal = "Marginal"
        var id: Self { self }
    }

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var fit: FitFilter = .all
    @State private var showCommunityModels = false

    private var results: [MLXModel] {
        model.catalogModels.filter { item in
            (showCommunityModels || item.trustLevel.isTrusted) &&
            (fit == .all || item.fitLevel?.lowercased() == fit.rawValue.lowercased()) &&
            (search.isEmpty || item.repository.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.catalogLoading && model.catalogModels.isEmpty {
                    ContentUnavailableView { ProgressView(); Text("Analyzing this Mac") } description: { Text("llmfit is measuring memory, GPU, and MLX compatibility.") }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { item in
                                ModelCatalogRow(item: item, selected: item.id == model.selectedModel.id) {
                                    model.selectedModel = item
                                    model.modelChanged()
                                    dismiss()
                                }
                                Divider()
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .accessibilityIdentifier("catalog.list")
                }
            }
            .navigationTitle("MLX Models for This Mac")
            .searchable(text: $search, prompt: "Search \(model.catalogModels.count) compatible models")
            .safeAreaInset(edge: .top) {
                if let hardware = model.catalogHardware {
                    HardwareSummary(hardware: hardware, updatedAt: model.catalogUpdatedAt, engineVersion: model.catalogEngineVersion)
                }
            }
            .toolbar {
                // NOTE: only .cancellationAction and .primaryAction actually render in this
                // sheet's toolbar on this SwiftUI/macOS combination -- every other sheet in
                // this app (RuntimeDiagnosticsView, ModelStorageView, PerformanceHistoryView)
                // independently sticks to just those two placements (plus .destructiveAction),
                // and confirmed live: a .principal Picker and two .secondaryAction items here
                // were silently never drawn, with no overflow affordance either. Everything
                // interactive is kept in .primaryAction/.cancellationAction so it's actually
                // reachable; the Fit picker is narrowed to make room alongside the buttons.
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Fit", selection: $fit) { ForEach(FitFilter.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 230).accessibilityIdentifier("catalog.fitFilter")
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Show Community Models", isOn: $showCommunityModels)
                        .help("Community conversions may have incompatible tokenizers or model files")
                        .accessibilityIdentifier("catalog.showCommunity")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.updateModelDatabase() } } label: {
                        if model.updatingModelDatabase { ProgressView().controlSize(.small) }
                        else { Label("Update Model Database…", systemImage: "arrow.triangle.2.circlepath.icloud") }
                    }
                    .disabled(model.updatingModelDatabase || model.catalogLoading)
                    .help("Fetch newly released trending and top-downloaded models from Hugging Face, then re-run the analysis. The only network request this app makes that isn't a model download.")
                    .accessibilityIdentifier("catalog.updateDatabase")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.loadCatalog(force: true) } } label: {
                        if model.catalogLoading { ProgressView().controlSize(.small) }
                        else { Label("Refresh Analysis", systemImage: "arrow.clockwise") }
                    }
                    .disabled(model.catalogLoading || model.updatingModelDatabase)
                    .help("Recheck current available memory and model fit")
                    .accessibilityIdentifier("catalog.refresh")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    if let result = model.modelDatabaseUpdateResult {
                        Text(result).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            .accessibilityIdentifier("catalog.updateDatabaseResult")
                    }
                    HStack {
                        Label("Apple Silicon · MLX only", systemImage: "apple.logo")
                        Spacer()
                        Text("\(results.count) models · ranked by llmfit")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).padding(.vertical, 10).background(.bar)
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .task { await model.loadCatalog() }
    }
}

struct HardwareSummary: View {
    let hardware: FitSystem
    let updatedAt: Date?
    /// The bundled llmfit engine's own version. Surfaced so a stale bundled binary
    /// -- frozen at whatever the app was last built with, since there's no version
    /// check anywhere -- shows up here instead of silently producing dated results.
    var engineVersion: String?

    var body: some View {
        HStack(spacing: 18) {
            Label(hardware.cpuName, systemImage: "laptopcomputer")
            Label("\(hardware.totalRAMGB, format: .number.precision(.fractionLength(0))) GB unified", systemImage: "memorychip")
            Label("\(hardware.gpuAvailableGB, format: .number.precision(.fractionLength(1))) GB available", systemImage: "gauge.with.dots.needle.67percent")
            Label(hardware.backend, systemImage: "sparkles")
            if let engineVersion {
                Label("llmfit \(engineVersion)", systemImage: "shippingbox")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("catalog.engineVersion")
            }
            Spacer()
            if let updatedAt { Text("Updated ").foregroundStyle(.tertiary) + Text(updatedAt, style: .relative).foregroundStyle(.secondary) }
        }
        .font(.caption).padding(.horizontal, 18).padding(.vertical, 11).background(.regularMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Detected hardware: \(hardware.cpuName), \(hardware.totalRAMGB, specifier: "%.0f") gigabytes unified memory, \(hardware.gpuAvailableGB, specifier: "%.1f") gigabytes currently available, \(hardware.backend)\(engineVersion.map { ", llmfit version \($0)" } ?? "")")
        .accessibilityIdentifier("catalog.hardware")
    }
}

struct ModelCatalogRow: View {
    let item: MLXModel
    let selected: Bool
    let choose: () -> Void

    var fitColor: Color {
        switch item.fitLevel { case "Perfect": .green; case "Good": .blue; default: .orange }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayName).fontWeight(.semibold).lineLimit(1)
                Text(item.repository).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Label(item.bestFor, systemImage: item.bestForIcon)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Label(item.trustLevel.rawValue, systemImage: item.trustLevel.isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(item.trustLevel.isTrusted ? .green : .orange)
                HStack(spacing: 10) {
                    Text(item.fitLevel ?? "Compatible").foregroundStyle(fitColor).fontWeight(.medium)
                    if let parameters = item.parameters { Text(parameters) }
                    Text(item.memory)
                    if let speed = item.estimatedTPS { Text("~\(speed, format: .number.precision(.fractionLength(1))) tok/s") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Button("Selected", action: choose).buttonStyle(.bordered).disabled(true)
                    .accessibilityIdentifier("catalog.use.\(item.id)")
            } else {
                Button("Use Model", action: choose).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("catalog.use.\(item.id)")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}
