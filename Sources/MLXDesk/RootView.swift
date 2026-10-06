import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationSplitView {
            ConversationSidebar(model: model, showDeleteConfirmation: $showDeleteConfirmation)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            ChatView(model: model)
                .inspector(isPresented: $model.inspectorPresented) { ModelInspector(model: model).inspectorColumnWidth(min: 260, ideal: 300, max: 360) }
        }
        .navigationTitle(model.conversations.selected?.title ?? "MLX Desk")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                RuntimeBadge(state: model.runtime)
                // A single, always-present Button whose label/action adapt to
                // state, NOT an if/else between two different Button
                // declarations: that conditional silently failed to register as
                // a toolbar item at all on this SwiftUI/macOS combination
                // (confirmed live via accessibility inspection -- RuntimeBadge
                // and the Inspector button on either side rendered fine, the
                // conditional branch never appeared, tried both as a separate
                // View struct and inlined). Toolbar item identity needs to stay
                // stable across state changes; varying content/modifiers on one
                // Button does that, branching between two Buttons doesn't.
                Button {
                    if model.workspaceURL != nil { model.closeWorkspace() } else { model.chooseWorkspace() }
                } label: {
                    Label(model.workspaceURL?.lastPathComponent ?? "Open Workspace", systemImage: model.workspaceURL != nil ? "folder.fill" : "folder")
                }
                .help(model.workspaceURL.map { "Close workspace \($0.path) (the model loses file access)" } ?? "Let the model read files and propose edits in a project folder")
                .accessibilityIdentifier(model.workspaceURL != nil ? "workspace.close" : "workspace.open")
                Button { model.inspectorPresented.toggle() } label: { Label("Model Inspector", systemImage: "sidebar.right") }
                    .help("Show model and generation settings")
                    .accessibilityIdentifier("inspector.toggle")
            }
        }
        .sheet(isPresented: $model.setupPresented) { SetupView(model: model) }
        .sheet(isPresented: $model.catalogPresented) { ModelCatalogView(model: model) }
        .sheet(isPresented: $model.onboardingPresented) { OnboardingView(model: model) }
        .sheet(isPresented: $model.storagePresented) { ModelStorageView(model: model) }
        .sheet(isPresented: $model.performancePresented) { PerformanceHistoryView(model: model) }
        .sheet(isPresented: Binding(get: { !model.pendingEdits.isEmpty }, set: { if !$0 { model.pendingEdits.removeAll() } })) {
            WorkspaceEditReviewView(model: model)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "Unknown error") }
        .alert("Model catalog unavailable", isPresented: Binding(get: { model.catalogError != nil }, set: { if !$0 { model.catalogError = nil } })) {
            Button("OK") { model.catalogError = nil }
        } message: { Text(model.catalogError ?? "Unknown error") }
        .alert("Couldn’t add this model", isPresented: Binding(get: { model.localModelImportError != nil }, set: { if !$0 { model.localModelImportError = nil } })) {
            Button("OK") { model.localModelImportError = nil }
        } message: { Text(model.localModelImportError ?? "Unknown error") }
        .confirmationDialog("Delete this conversation?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { if let id = model.conversations.selection { model.conversations.remove(id) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This action can’t be undone.") }
    }
}

struct ConversationSidebar: View {
    @Bindable var model: AppModel
    @Bindable var store: ConversationStore
    @Binding var showDeleteConfirmation: Bool

    init(model: AppModel, showDeleteConfirmation: Binding<Bool>) {
        self.model = model; self.store = model.conversations; _showDeleteConfirmation = showDeleteConfirmation
    }

    var body: some View {
        List(selection: $store.selection) {
            Section("Conversations") {
                ForEach(store.filtered) { conversation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title).fontWeight(.medium).lineLimit(1)
                        Text(conversation.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(conversation.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { store.selection = conversation.id; showDeleteConfirmation = true }
                    }
                    .accessibilityLabel("Conversation, \(conversation.title)")
                }
            }
        }
        .searchable(text: $store.searchText, prompt: "Search conversations")
        .overlay { if store.filtered.isEmpty { ContentUnavailableView.search(text: store.searchText) } }
        .safeAreaInset(edge: .bottom) {
            Button { store.createConversation() } label: { Label("New Conversation", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large).padding()
                .accessibilityIdentifier("conversation.new")
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showDeleteConfirmation = true } label: { Label("Delete Conversation", systemImage: "trash") }
                    .disabled(store.selection == nil)
                    .accessibilityIdentifier("conversation.delete")
            }
        }
    }
}

struct RuntimeBadge: View {
    let state: RuntimeState
    var color: Color {
        switch state { case .running: .green; case .failed, .unavailable: .orange; case .downloading, .starting, .checking: .blue; case .ready: .secondary }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(state.label).font(.caption).fontWeight(.medium)
        }
        .padding(.horizontal, 9).padding(.vertical, 5).background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine).accessibilityIdentifier("runtime.status")
    }
}
