import Foundation
import UIKit

@Observable @MainActor
final class ConversationStore {
    var conversations: [Conversation] = []
    var activeConversationId: UUID?

    private static let rootDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static var indexURL: URL { rootDir.appendingPathComponent("conversations.json") }

    // MARK: – Lifecycle

    init() {
        migrateIfNeeded()
        conversations = Self.loadIndex()
        if conversations.isEmpty {
            let first = createNew()
            activeConversationId = first.id
        } else {
            activeConversationId = conversations.first?.id
        }
    }

    // MARK: – Public API

    @discardableResult
    func createNew() -> Conversation {
        let conv = Conversation()
        conversations.insert(conv, at: 0)
        activeConversationId = conv.id
        saveIndex()
        return conv
    }

    func loadMessages(for conversationId: UUID) -> [ChatMessage] {
        let dir = Self.conversationDir(conversationId)
        return MessageCache.load(from: dir)
    }

    func saveMessages(_ messages: [ChatMessage], for conversationId: UUID) {
        let dir = Self.conversationDir(conversationId)
        MessageCache.save(messages, to: dir)

        // Update conversation metadata
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].messageCount = messages.count
            conversations[idx].lastMessageAt = messages.last?.timestamp ?? Date()
            if let lastText = messages.last(where: { $0.text != "" }) {
                let preview = lastText.text
                conversations[idx].preview = String(preview.prefix(80))
            }
            // Auto-title from first user message
            if conversations[idx].title == "Новый диалог",
               let firstUser = messages.first(where: { $0.role == .user }) {
                conversations[idx].title = Conversation.autoTitle(from: firstUser.text)
            }
            saveIndex()
        }
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        let dir = Self.conversationDir(id)
        try? FileManager.default.removeItem(at: dir)
        saveIndex()
    }

    func togglePin(_ id: UUID) {
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].isPinned.toggle()
            saveIndex()
        }
    }

    var activeConversation: Conversation? {
        conversations.first { $0.id == activeConversationId }
    }

    // MARK: – Persistence

    private static func conversationDir(_ id: UUID) -> URL {
        let dir = rootDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func loadIndex() -> [Conversation] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Conversation].self, from: data)) ?? []
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(conversations) {
            try? data.write(to: Self.indexURL)
        }
    }

    // MARK: – Migration from legacy MessageCache

    private func migrateIfNeeded() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let legacyDir = docs.appendingPathComponent("MessageCache", isDirectory: true)
        let legacyIndex = legacyDir.appendingPathComponent("index.json")

        guard FileManager.default.fileExists(atPath: legacyIndex.path) else { return }
        // Already migrated?
        guard !FileManager.default.fileExists(atPath: Self.indexURL.path) else { return }

        let messages = MessageCache.load(from: legacyDir)
        guard !messages.isEmpty else { return }

        let conv = Conversation(
            title: Conversation.autoTitle(from: messages.first(where: { $0.role == .user })?.text ?? ""),
            createdAt: messages.first?.timestamp ?? Date()
        )
        var mutable = conv
        mutable.lastMessageAt = messages.last?.timestamp ?? Date()
        mutable.messageCount = messages.count
        mutable.preview = String((messages.last(where: { $0.text != "" })?.text ?? "").prefix(80))

        conversations = [mutable]
        activeConversationId = mutable.id
        saveIndex()

        let newDir = Self.conversationDir(mutable.id)
        MessageCache.save(messages, to: newDir)

        // Clean up legacy directory
        try? FileManager.default.removeItem(at: legacyDir)
    }
}
