import Foundation

/// Single entry in the outbox — one user-originated message that has not yet been
/// acknowledged by the server. Codable so the store survives app relaunches.
struct OutboxEntry: Codable, Equatable {
    /// `clientMessageId` — matches the id used on the `ChatMessage` in the UI.
    let id: String
    let conversationId: UUID?
    let createdAt: Date
    var lastAttempt: Date?
    var attempts: Int
    /// JSON-serialized WS payload. Sent verbatim on flush.
    let payload: Data
    /// Short text used to render the row when the cached ChatMessage is gone.
    let textPreview: String
    let hasAttachments: Bool
    /// Mirrors the UI-side status — `.sending`, `.sent`, `.failed`. `.delivered` entries are removed.
    var deliveryStatus: DeliveryStatus

    init(id: String, conversationId: UUID?, createdAt: Date, lastAttempt: Date? = nil,
         attempts: Int = 0, payload: Data, textPreview: String, hasAttachments: Bool,
         deliveryStatus: DeliveryStatus = .sending) {
        self.id = id
        self.conversationId = conversationId
        self.createdAt = createdAt
        self.lastAttempt = lastAttempt
        self.attempts = attempts
        self.payload = payload
        self.textPreview = textPreview
        self.hasAttachments = hasAttachments
        self.deliveryStatus = deliveryStatus
    }
}

/// Persisted FIFO of pending outbound messages. Survives app relaunch and crashes.
/// Single owner: `WebSocketClient`. Single writer: `@MainActor`.
@Observable @MainActor final class OutboxStore {
    var entries: [OutboxEntry] = []   // sorted by createdAt asc

    @ObservationIgnored private let url: URL
    @ObservationIgnored static let maxEntries = 100

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("queue.json")
        load()
    }

    func enqueue(_ entry: OutboxEntry) {
        entries.append(entry)
        entries.sort { $0.createdAt < $1.createdAt }
        save()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let arr = try? dec.decode([OutboxEntry].self, from: data) {
            entries = arr.sorted { $0.createdAt < $1.createdAt }
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(entries) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            print("OutboxStore: save failed — \(error)")
        }
    }
}
