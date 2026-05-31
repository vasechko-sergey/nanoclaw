import Foundation
import UIKit

// MARK: - Local message cache (formerly Services/MessageCache.swift)
//
// Per-conversation JSON+JPEG cache used by `ConversationStore` for the v1
// file-based conversation index that several views still depend on. The v2
// WebSocket facade no longer reads or writes this — its source of truth is
// the GRDB-backed `ConversationStoreV2` (see `WebSocketClientV2`). Kept here
// so the conversation list, drawer, profile and settings views continue to
// render until their reads are migrated to v2 storage.

private struct CachedMessage: Codable {
    let id: String
    let role: String          // "user" | "assistant" | "system"
    let kind: String          // "text" | "image" | "file" | "action" | "status"
    let text: String?
    let imageFile: String?
    let filename: String?
    let timestamp: Date

    let fileName: String?
    let fileSize: Int64?
    let fileMimeType: String?
    let fileUrl: String?

    let buttons: [CachedButton]?
    let actionAnswered: Bool?
    let actionSelectedId: String?

    let statusLevel: String?
    let statusKind: String?

    let deliveryStatus: String?
}

private struct CachedButton: Codable {
    let id: String
    let label: String
    let style: String
}

enum MessageCache {
    static let maxMessages = 150

    static func load(from dir: URL) -> [ChatMessage] {
        let indexURL = dir.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode([CachedMessage].self, from: data)
        else { return [] }

        return cached.compactMap { cm in
            let role: ChatMessage.Role
            switch cm.role {
            case "user":      role = .user
            case "system":    role = .system
            default:          role = .assistant
            }

            let restoredStatus: DeliveryStatus = {
                switch cm.deliveryStatus {
                case "sent": return .sent
                case "failed": return .failed
                default: return .delivered
                }
            }()

            switch cm.kind {
            case "text":
                guard let t = cm.text else { return nil }
                var msg = ChatMessage.text(cm.id, role: role, text: t, timestamp: cm.timestamp)
                msg.deliveryStatus = restoredStatus
                return msg

            case "image":
                guard let file = cm.imageFile, let fname = cm.filename else { return nil }
                let url = dir.appendingPathComponent(file)
                if let d = try? Data(contentsOf: url), let img = UIImage(data: d) {
                    var msg = ChatMessage.image(cm.id, role: role, image: img, filename: fname, timestamp: cm.timestamp)
                    msg.deliveryStatus = restoredStatus
                    return msg
                }
                var msg = ChatMessage.text(cm.id, role: role, text: "🖼 \(fname) (изображение недоступно)", timestamp: cm.timestamp)
                msg.deliveryStatus = restoredStatus
                return msg

            case "file":
                guard let name = cm.fileName else { return nil }
                let info = FileInfo(
                    name: name,
                    size: cm.fileSize ?? 0,
                    mimeType: cm.fileMimeType ?? "application/octet-stream",
                    url: cm.fileUrl,
                    thumbnail: nil
                )
                var msg = ChatMessage.file(cm.id, role: role, info: info, timestamp: cm.timestamp)
                msg.deliveryStatus = restoredStatus
                return msg

            case "action":
                guard let text = cm.text else { return nil }
                let buttons = (cm.buttons ?? []).map { b in
                    ActionButton(id: b.id, label: b.label, style: ActionButton.Style(rawValue: b.style) ?? .primary)
                }
                var actionInfo = ActionInfo(text: text, buttons: buttons)
                actionInfo.answered = cm.actionAnswered ?? false
                actionInfo.selectedId = cm.actionSelectedId
                var msg = ChatMessage(id: cm.id, role: role, content: .action(actionInfo), timestamp: cm.timestamp)
                msg.deliveryStatus = restoredStatus
                return msg

            case "status":
                guard let text = cm.text else { return nil }
                let level = StatusInfo.Level(rawValue: cm.statusLevel ?? "info") ?? .info
                var msg = ChatMessage.status(cm.id, text: text, level: level, kind: cm.statusKind, timestamp: cm.timestamp)
                msg.deliveryStatus = restoredStatus
                return msg

            default:
                return nil
            }
        }
    }

    static func save(_ messages: [ChatMessage], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexURL = dir.appendingPathComponent("index.json")

        let recent = messages.suffix(maxMessages)
        let cached: [CachedMessage] = recent.map { msg in
            let role: String
            switch msg.role {
            case .user:      role = "user"
            case .assistant: role = "assistant"
            case .system:    role = "system"
            }

            switch msg.content {
            case .text(let t):
                return CachedMessage(id: msg.id, role: role, kind: "text",
                                     text: t, imageFile: nil, filename: nil, timestamp: msg.timestamp,
                                     fileName: nil, fileSize: nil, fileMimeType: nil, fileUrl: nil,
                                     buttons: nil, actionAnswered: nil, actionSelectedId: nil,
                                     statusLevel: nil, statusKind: nil,
                                     deliveryStatus: msg.deliveryStatus.rawValue)

            case .image(let img, let fname):
                let file = msg.id + ".jpg"
                if let d = img.jpegData(compressionQuality: 0.85) {
                    do { try d.write(to: dir.appendingPathComponent(file), options: .atomic) }
                    catch { Log.warn(.cache, "image write failed for \(file): \(error)") }
                }
                return CachedMessage(id: msg.id, role: role, kind: "image",
                                     text: nil, imageFile: file, filename: fname, timestamp: msg.timestamp,
                                     fileName: nil, fileSize: nil, fileMimeType: nil, fileUrl: nil,
                                     buttons: nil, actionAnswered: nil, actionSelectedId: nil,
                                     statusLevel: nil, statusKind: nil,
                                     deliveryStatus: msg.deliveryStatus.rawValue)

            case .file(let info):
                return CachedMessage(id: msg.id, role: role, kind: "file",
                                     text: nil, imageFile: nil, filename: nil, timestamp: msg.timestamp,
                                     fileName: info.name, fileSize: info.size, fileMimeType: info.mimeType, fileUrl: info.url,
                                     buttons: nil, actionAnswered: nil, actionSelectedId: nil,
                                     statusLevel: nil, statusKind: nil,
                                     deliveryStatus: msg.deliveryStatus.rawValue)

            case .action(let info):
                let buttons = info.buttons.map { CachedButton(id: $0.id, label: $0.label, style: $0.style.rawValue) }
                return CachedMessage(id: msg.id, role: role, kind: "action",
                                     text: info.text, imageFile: nil, filename: nil, timestamp: msg.timestamp,
                                     fileName: nil, fileSize: nil, fileMimeType: nil, fileUrl: nil,
                                     buttons: buttons, actionAnswered: info.answered, actionSelectedId: info.selectedId,
                                     statusLevel: nil, statusKind: nil,
                                     deliveryStatus: msg.deliveryStatus.rawValue)

            case .status(let info):
                return CachedMessage(id: msg.id, role: role, kind: "status",
                                     text: info.text, imageFile: nil, filename: nil, timestamp: msg.timestamp,
                                     fileName: nil, fileSize: nil, fileMimeType: nil, fileUrl: nil,
                                     buttons: nil, actionAnswered: nil, actionSelectedId: nil,
                                     statusLevel: info.level.rawValue, statusKind: info.kind,
                                     deliveryStatus: msg.deliveryStatus.rawValue)
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(cached) {
            do { try data.write(to: indexURL, options: .atomic) }
            catch { Log.error(.cache, "index write failed: \(error)") }
        }

        pruneOrphanImages(in: dir, keeping: Set(recent.compactMap { msg -> String? in
            if case .image = msg.content { return msg.id + ".jpg" }
            return nil
        }))
    }

    private static func pruneOrphanImages(in dir: URL, keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where f.hasSuffix(".jpg") && !names.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }
}

@Observable @MainActor
final class ConversationStore {
    var conversations: [Conversation] = []
    var activeConversationId: UUID?

    /// Weak reference to the GRDB-backed v2 store. Wired lazily by
    /// `AppCoordinator` once `WebSocketClientV2` has built its `AppV2Stack`
    /// (the v2 store doesn't exist at coordinator-init time). All mutating
    /// operations on this v1 store forward into the v2 store so the GRDB
    /// `conversations` table stays in sync with the JSON index that drives
    /// the drawer. This is what makes "tap conversation → show messages"
    /// work: `WebSocketClientV2.restartObservation` joins on the v2
    /// `conversations` row, so the row must exist there for the UUID the
    /// drawer hands to `.open(conv)`.
    @ObservationIgnored private weak var v2Store: ConversationStoreV2?

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

    /// Wire the GRDB-backed v2 store and backfill every in-memory v1
    /// conversation into the v2 `conversations` table. Idempotent — uses
    /// `INSERT OR IGNORE` on the v2 side so repeated calls (e.g. on
    /// reconnect) are safe. Must be called on the main actor.
    func attachV2(_ store: ConversationStoreV2) {
        self.v2Store = store
        syncAllToV2(store)
    }

    private func syncAllToV2(_ store: ConversationStoreV2) {
        for conv in conversations {
            do {
                try store.createConversation(
                    id: conv.id.uuidString,
                    title: conv.title.isEmpty ? nil : conv.title,
                    createdAt: conv.createdAt
                )
            } catch {
                Log.warn(.cache, "ConversationStore.syncAllToV2 failed for \(conv.id): \(error)")
            }
        }
    }

    // MARK: – Public API

    @discardableResult
    func createNew() -> Conversation {
        let conv = Conversation()
        conversations.insert(conv, at: 0)
        activeConversationId = conv.id
        saveIndex()
        // Mirror into v2 so the chat-view observation finds a row immediately,
        // even before the user sends the first message.
        if let v2 = v2Store {
            do {
                try v2.createConversation(
                    id: conv.id.uuidString,
                    title: conv.title.isEmpty ? nil : conv.title,
                    createdAt: conv.createdAt
                )
            } catch {
                Log.warn(.cache, "ConversationStore.createNew v2 sync failed: \(error)")
            }
        }
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
        // Mirror the delete as an archive flip in v2 (keeps message history
        // recoverable on disk while hiding the row from the drawer).
        if let v2 = v2Store {
            do { try v2.archiveConversation(id: id.uuidString) }
            catch { Log.warn(.cache, "ConversationStore.deleteConversation v2 sync failed: \(error)") }
        }
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
