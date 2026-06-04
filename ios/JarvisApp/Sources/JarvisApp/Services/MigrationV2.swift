import Foundation

/// Stubbed during the single-chat refactor. The legacy v1→v2 import logic that
/// lived here is retired by the v3-single-chat migration in `Schema.swift` —
/// there are no more conversations to lift forward. The whole file is scheduled
/// for deletion in the next task of `docs/superpowers/plans/2026-06-01-jarvis-phase1.md`;
/// this empty implementation only exists to keep `AppV2Bootstrap` compiling
/// during the transition.
enum MigrationV2 {
    /// Stable token historically used by tests for the legacy fallback thread.
    /// Kept so any lingering external reference still resolves while the
    /// legacy test files are excluded from the build.
    static let legacyFallbackConversationId = "legacy-v1"

    /// No-op stub. Real migration is gone; v3-single-chat starts with an empty
    /// timeline by design.
    static func runIfNeeded(
        documentsURL: URL,
        store: ConversationStoreV2,
        fallbackConversationId: String = legacyFallbackConversationId
    ) throws {
        _ = documentsURL
        _ = store
        _ = fallbackConversationId
    }
}
