import Foundation
import GRDB

/// Stub shim during the single-chat refactor.
///
/// The v3-single-chat schema migration removed the `conversations`,
/// `inbound_dedup`-grouping and per-conversation indexes that the original
/// `ConversationStore` shim was built on top of. The whole drawer concept is
/// scheduled for deletion in the next task of
/// `docs/superpowers/plans/2026-06-01-jarvis-phase1.md`, which also rips out
/// every view file that consumes this type (ConversationListView,
/// RightDrawerContent, ProfileView, OrbHomeView, parts of ChatView/SettingsView,
/// AppCoordinator's `recordUserSend`/`recordIncoming` wiring).
///
/// To keep the project compiling during the transitional state — so the new
/// `MessageTimeline` and its tests can land — this file only preserves the
/// public API surface those consumers touch. All methods are inert no-ops and
/// `conversations` is always empty. None of the legacy behaviour
/// (auto-titling, pinning, active-id persistence) is meaningful any more; the
/// single chat thread is pinned at `ios:default`.
@Observable @MainActor
final class ConversationStore {

    /// Always empty in the single-chat world. Kept so drawer views compile
    /// until they are deleted in the next task.
    private(set) var conversations: [Conversation] = []

    /// Always nil. The single-chat app does not address chats by id.
    var activeConversationId: UUID?

    @ObservationIgnored private let v2: ConversationStoreV2

    init(v2: ConversationStoreV2) {
        self.v2 = v2
    }

    /// Returns a fresh stub `Conversation` for the few view sites that still
    /// expect a created row. Does not persist anything.
    @discardableResult
    func createNew() -> Conversation {
        Conversation()
    }

    func deleteConversation(_ id: UUID) { _ = id }
    func togglePin(_ id: UUID) { _ = id }

    var activeConversation: Conversation? { nil }

    func recordUserSend(conversationId: UUID, text: String, at date: Date = Date()) {
        _ = conversationId; _ = text; _ = date
    }

    func recordIncoming(conversationId: UUID, at date: Date = Date()) {
        _ = conversationId; _ = date
    }
}
