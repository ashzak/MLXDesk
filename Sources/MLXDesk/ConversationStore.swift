import Foundation
import Observation

@MainActor @Observable
final class ConversationStore {
    private(set) var conversations: [Conversation] = []
    var selection: UUID?
    var searchText = ""
    private let fileURL: URL?

    init(fileURL: URL? = ConversationStore.defaultURL, seed: Bool = false) {
        self.fileURL = fileURL
        if seed {
            conversations = [.init(title: "Welcome to MLX Desk", messages: [
                .init(role: .assistant, content: "Your private coding model is ready. Ask me to explain code, plan a feature, or draft an implementation.")
            ])]
        } else { load() }
        if conversations.isEmpty { createConversation() }
        selection = conversations.first?.id
    }

    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "MLXDesk/conversations.json")
    }

    var filtered: [Conversation] {
        guard !searchText.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.messages.contains { $0.content.localizedCaseInsensitiveContains(searchText) } }
    }

    var selected: Conversation? { conversations.first { $0.id == selection } }

    func createConversation() {
        let item = Conversation(title: "New conversation")
        conversations.insert(item, at: 0)
        selection = item.id
        persist()
    }

    func append(_ message: ChatMessage, to id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.append(message)
        conversations[index].updatedAt = .now
        if message.role == .user && conversations[index].title == "New conversation" {
            conversations[index].title = String(message.content.prefix(42))
        }
        persist()
    }

    func updateLastAssistant(_ content: String, in id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              let messageIndex = conversations[index].messages.lastIndex(where: { $0.role == .assistant }) else { return }
        conversations[index].messages[messageIndex].content = content
    }

    func remove(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { createConversation() }
        selection = conversations.first?.id
        persist()
    }

    func clearMessages(in id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages = []
        conversations[index].title = "New conversation"
        persist()
    }

    func persist() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(conversations) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = decoded.map { conversation in
            var repaired = conversation
            if repaired.messages.last?.role == .assistant && repaired.messages.last?.content.isEmpty == true {
                repaired.messages[repaired.messages.count - 1].content = "Response interrupted before completion. You can send the prompt again."
            }
            return repaired
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
