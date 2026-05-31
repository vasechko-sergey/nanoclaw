import Foundation
import GRDB

/// V2-backed replacement for the legacy file-based `Services/ConversationStore`.
/// Preserves the observable surface (`conversations`, `activeConversationId`,
/// `createNew()`, `deleteConversation(_:)`, `togglePin(_:)`) so the six view
/// sites (ChatView, ConversationListView+DrawerContent, ProfileView,
/// RightDrawerContent, SettingsView, OrbHomeView) didn't have to change. All
/// reads/writes are persisted in GRDB via `ConversationStoreV2`; the in-memory
/// `conversations` array is rebuilt from a `ValueObservation` on the
/// `conversations` table joined with the `messages` aggregate.
///
/// The legacy v1 store maintained an in-memory `[Conversation]` from
/// `Documents/Conversations/conversations.json` and stored per-conversation
/// message bodies in `index.json` files alongside it. That whole on-disk shape
/// is retired — `MigrationV2.runIfNeeded` lifts existing indexes + cached
/// messages into GRDB on first launch, after which the v1 dirs become orphan
/// disk usage (we intentionally don't auto-delete them).
@Observable @MainActor
final class ConversationStore {

    /// Drawer-visible conversations (non-archived, pinned first then by
    /// `lastMessageAt` DESC). Mirrors the legacy property name + ordering.
    private(set) var conversations: [Conversation] = []

    /// Currently-open conversation. Persisted via the `kv` table so a cold
    /// launch lands the user back in the same chat.
    var activeConversationId: UUID? {
        didSet {
            guard activeConversationId != oldValue else { return }
            persistActive(activeConversationId)
        }
    }

    @ObservationIgnored private let v2: ConversationStoreV2
    @ObservationIgnored private var conversationsCancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var activeIdCancellable: AnyDatabaseCancellable?

    init(v2: ConversationStoreV2) {
        self.v2 = v2
        bootstrap()
    }

    // MARK: - Bootstrap
    //
    // Mirrors the legacy init contract: if no conversations exist at all,
    // create one and select it; otherwise restore the persisted active id (or
    // fall back to the first row). Then attach a live observation.

    private func bootstrap() {
        // Synchronous initial seed so view-models that read `conversations`
        // on first render see something coherent even before the observation
        // tick lands.
        let summaries = (try? v2.listConversations()) ?? []
        var initial = summaries.compactMap(Conversation.init(summary:))

        if initial.isEmpty {
            let conv = Conversation()
            try? v2.createConversation(
                id: conv.id.uuidString,
                title: conv.title.isEmpty ? nil : conv.title,
                createdAt: conv.createdAt
            )
            initial = [conv]
            self.activeConversationId = conv.id
            persistActive(conv.id)
        } else {
            // Restore persisted active id when present; otherwise pick the
            // first row (matches v1 behaviour on cold launch).
            let persistedRaw = (try? v2.activeConversationId()) ?? nil
            if let raw = persistedRaw, let uuid = UUID(uuidString: raw),
               initial.contains(where: { $0.id == uuid }) {
                self.activeConversationId = uuid
            } else {
                self.activeConversationId = initial.first?.id
                if let id = self.activeConversationId {
                    persistActive(id)
                }
            }
        }
        self.conversations = initial
        startObservation()
    }

    private func startObservation() {
        conversationsCancellable?.cancel()
        conversationsCancellable = v2.observeConversations().start(
            in: v2.writer,
            scheduling: .async(onQueue: .main),
            onError: { error in
                Log.warn(.cache, "ConversationStore observation error: \(error)")
            },
            onChange: { [weak self] summaries in
                guard let self else { return }
                self.conversations = summaries.compactMap(Conversation.init(summary:))
            }
        )

        // Observe the persisted active id so external mutators (e.g. proactive
        // push deep-link writing through the store) propagate into the view.
        activeIdCancellable?.cancel()
        activeIdCancellable = v2.observeActiveConversationId().start(
            in: v2.writer,
            scheduling: .async(onQueue: .main),
            onError: { error in
                Log.warn(.cache, "ConversationStore active id observation error: \(error)")
            },
            onChange: { [weak self] raw in
                guard let self else { return }
                let parsed = raw.flatMap { UUID(uuidString: $0) }
                if parsed != self.activeConversationId {
                    self.activeConversationId = parsed
                }
            }
        )
    }

    private func persistActive(_ id: UUID?) {
        do { try v2.setActiveConversationId(id?.uuidString) }
        catch { Log.warn(.cache, "ConversationStore persistActive failed: \(error)") }
    }

    // MARK: - Public API (mirrors legacy)

    /// Create a new "Новый диалог" conversation, select it, and return the
    /// stub. The created row is immediately visible in the drawer (the
    /// observation tick lands on the next runloop, but we also splice the row
    /// into `conversations` synchronously so callers that read
    /// `activeConversation` right after `createNew()` see consistent state).
    @discardableResult
    func createNew() -> Conversation {
        let conv = Conversation()
        do {
            try v2.createConversation(
                id: conv.id.uuidString,
                title: conv.title.isEmpty ? nil : conv.title,
                createdAt: conv.createdAt
            )
        } catch {
            Log.warn(.cache, "ConversationStore.createNew insert failed: \(error)")
        }
        // Synchronous mirror — the observation will reconcile shortly.
        if !conversations.contains(where: { $0.id == conv.id }) {
            conversations.insert(conv, at: 0)
        }
        self.activeConversationId = conv.id
        return conv
    }

    /// Delete a conversation (hard delete in v2 — messages + row both go).
    func deleteConversation(_ id: UUID) {
        do {
            try v2.deleteConversation(id: id.uuidString)
        } catch {
            Log.warn(.cache, "ConversationStore.deleteConversation failed: \(error)")
        }
        conversations.removeAll { $0.id == id }
        if activeConversationId == id {
            activeConversationId = conversations.first?.id
        }
    }

    /// Flip the pin state. The observation will refresh ordering on the next
    /// tick (pinned float to the top via the summary query).
    func togglePin(_ id: UUID) {
        do {
            try v2.togglePinned(id: id.uuidString)
        } catch {
            Log.warn(.cache, "ConversationStore.togglePin failed: \(error)")
        }
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].isPinned.toggle()
        }
    }

    /// Active conversation row, if any. Mirrors the legacy computed property
    /// — used by `ProfileFormBody.memberSince` and the home satellites.
    var activeConversation: Conversation? {
        conversations.first { $0.id == activeConversationId }
    }

    // MARK: - Send/receive hooks
    //
    // Wired by `AppCoordinator`. The shim only updates conversation metadata
    // (title auto-pick + last_message_at touch) — actual message persistence
    // is owned by `WebSocketClientV2` writing into the `messages` table.

    /// Called by the coordinator when the agent sends a message into a chat.
    /// Auto-titles a fresh "Новый диалог" using the first user line, and
    /// bumps `last_message_at` so the row floats to the top of the drawer.
    func recordUserSend(conversationId: UUID, text: String, at date: Date = Date()) {
        let ts = Int(date.timeIntervalSince1970 * 1000)
        do { try v2.touchLastMessageAt(id: conversationId.uuidString, ts: ts) }
        catch { Log.warn(.cache, "ConversationStore.recordUserSend touch failed: \(error)") }

        // Auto-title from first user message if still on the default stub.
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }),
           conversations[idx].title == "Новый диалог", !text.isEmpty {
            let newTitle = Conversation.autoTitle(from: text)
            do { try v2.renameConversation(id: conversationId.uuidString, title: newTitle) }
            catch { Log.warn(.cache, "ConversationStore.recordUserSend rename failed: \(error)") }
        }
    }

    /// Called when an inbound message lands for a conversation (active or
    /// background). Bumps `last_message_at` so the row floats up.
    func recordIncoming(conversationId: UUID, at date: Date = Date()) {
        let ts = Int(date.timeIntervalSince1970 * 1000)
        do { try v2.touchLastMessageAt(id: conversationId.uuidString, ts: ts) }
        catch { Log.warn(.cache, "ConversationStore.recordIncoming touch failed: \(error)") }
    }
}
