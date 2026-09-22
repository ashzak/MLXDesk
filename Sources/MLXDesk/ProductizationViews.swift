import AppKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 48)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.onboardingTitle).font(.largeTitle.bold())
                Text("MLX Desk analyzes unified memory, recommends verified MLX models, and keeps inference on this Mac.").font(.title3).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                OnboardingRow(icon: "memorychip", title: "Hardware-aware", detail: "Models are ranked for this Mac using llmfit.")
                OnboardingRow(icon: "checkmark.shield", title: "Compatibility checks", detail: "Disk, cache, tokenizer, and readiness checks run before chat.")
                OnboardingRow(icon: "lock.shield", title: "Private by design", detail: "Prompts and responses are never included in support exports.")
            }
            HStack {
                Spacer()
                Button("Choose a Model") { model.completeOnboarding() }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.continue")
            }
        }
        .padding(36).frame(width: 650)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("onboarding.sheet")
    }
}

private struct OnboardingRow: View {
    let icon: String, title: String, detail: String
    var body: some View {
        GridRow {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading) { Text(title).fontWeight(.semibold); Text(detail).foregroundStyle(.secondary) }
        }
    }
}

struct ModelStorageView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: CachedModelEntry?
    @State private var verification: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if model.storageLoading { ProgressView("Scanning model cache…") }
                else if model.cachedModels.isEmpty { ContentUnavailableView("No Downloaded Models", systemImage: "externaldrive", description: Text("Models appear here after a download begins.")) }
                else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.cachedModels) { entry in
                            HStack(spacing: 14) {
                            Image(systemName: entry.incomplete ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                                .foregroundStyle(entry.incomplete ? .orange : .green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.repository).fontWeight(.medium).textSelection(.enabled)
                                Text("\(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)) · \(entry.incomplete ? "Incomplete — resume available" : "Complete")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let result = verification[entry.id] { Text(result).font(.caption).foregroundStyle(result == "Verified" ? .green : .orange) }
                            }
                            Spacer()
                            Button("Verify") { Task { verification[entry.id] = await model.verifyCachedModel(entry) } }
                            Button(entry.incomplete ? "Resume" : "Use Model") { Task { await model.resumeCachedModel(entry, startImmediately: entry.incomplete) } }.buttonStyle(.borderedProminent)
                            Button { Task { await model.revealCachedModel(entry) } } label: { Image(systemName: "folder") }.help("Reveal in Finder").accessibilityLabel("Reveal model in Finder")
                            Button(role: .destructive) { pendingDelete = entry } label: { Image(systemName: "trash") }.help("Delete model files").accessibilityLabel("Delete model")
                            }.padding(.vertical, 10).accessibilityElement(children: .contain)
                            Divider()
                            }
                        }.padding(.horizontal, 18)
                    }
                }
            }
            .navigationTitle(L10n.storageTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { Task { await model.loadStorage() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task { await model.loadStorage() }
        .confirmationDialog("Delete this model’s cached files?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Model Files", role: .destructive) { if let entry = pendingDelete { Task { await model.deleteCachedModel(entry) } }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("The model can be downloaded again later. Conversations are not deleted.") }
    }
}

struct PerformanceHistoryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.performanceSamples) { sample in
                    VStack(alignment: .leading, spacing: 5) {
                    Text(sample.modelID).fontWeight(.medium)
                    HStack { Text("\(sample.tokensPerSecond, format: .number.precision(.fractionLength(1))) tok/s"); Text("First token \(sample.firstTokenSeconds, format: .number.precision(.fractionLength(2)))s"); Spacer(); Text(sample.timestamp, style: .relative) }
                        .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    }
                }.padding(.horizontal, 18)
            }
            .overlay { if model.performanceSamples.isEmpty { ContentUnavailableView("No Performance History", systemImage: "gauge", description: Text("Completed generations will appear here.")) } }
            .navigationTitle("Performance History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) { Button("Clear History", role: .destructive) { Task { await model.clearPerformanceHistory() } }.disabled(model.performanceSamples.isEmpty) }
            }
        }.frame(minWidth: 650, minHeight: 440).task { await model.loadPerformanceHistory() }
    }
}
