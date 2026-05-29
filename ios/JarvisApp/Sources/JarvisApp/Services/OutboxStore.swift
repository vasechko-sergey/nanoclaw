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

    @ObservationIgnored static let maxEntries = 100
    @ObservationIgnored private let url: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("queue.json")
        load()
    }

    /// Enqueue a new entry. Returns `true` on success, `false` if the outbox is
    /// full and no `.failed` entry is available to evict. Callers MUST handle
    /// the `false` case — a silent drop means a lost user message.
    func enqueue(_ entry: OutboxEntry) -> Bool {
        if entries.count >= Self.maxEntries {
            // Drop the oldest .failed entry, if any
            if let idx = entries.firstIndex(where: { $0.deliveryStatus == .failed }) {
                entries.remove(at: idx)
            } else {
                // Nothing droppable — refuse
                return false
            }
        }
        entries.append(entry)
        entries.sort { $0.createdAt < $1.createdAt }
        save()
        return true
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Mark an entry as just-attempted: bumps `attempts`, sets `lastAttempt = now`.
    func bumpAttempt(_ id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].attempts += 1
        entries[idx].lastAttempt = Date()
        save()
    }

    /// Whether the flush loop should attempt this entry now. Skip if there have
    /// been 5+ attempts within the last 60 seconds (tight-loop guard).
    func shouldRetry(_ id: String, now: Date = Date()) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        if entry.attempts < 5 { return true }
        guard let last = entry.lastAttempt else { return true }
        return now.timeIntervalSince(last) > 60
    }

    func load() {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // No file yet — normal on first launch.
            return
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let arr = try dec.decode([OutboxEntry].self, from: data)
            entries = arr.sorted { $0.createdAt < $1.createdAt }
        } catch {
            Log.warn(.outbox, "decode failed — \(error). Quarantining bad file.")
            let ts = Int(Date().timeIntervalSince1970)
            let bad = url.appendingPathExtension("corrupt-\(ts)")
            _ = try? FileManager.default.moveItem(at: url, to: bad)
            // entries stays [] — next save writes a fresh queue.json.
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try enc.encode(entries)
        } catch {
            Log.error(.outbox, "encode failed — \(error)")
            return
        }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            Log.error(.outbox, "save failed — \(error)")
            // Clean up orphaned tmp on failure
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
