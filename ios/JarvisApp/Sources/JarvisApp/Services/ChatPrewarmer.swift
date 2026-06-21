import Foundation

/// Warms the chat render caches for ALL stored messages at launch, off the main
/// thread, so the first open of any agent's chat — and switching between agents
/// — is instant instead of paying a per-message markdown parse / image decode on
/// first render. Runs behind the splash.
///
/// Reads the DB directly (not the live `ws.messages` observation), so it works
/// even before / without a server connection. Best-effort: if the user reaches a
/// chat before it finishes, those messages just parse lazily (and memoize) as
/// before — nothing blocks and nothing is incorrect, only un-warmed.
enum ChatPrewarmer {
    static func warmAll(store: ConversationStoreV2) {
        Task.detached(priority: .utility) {
            let rows = (try? store.allRows()) ?? []
            let decoder = JSONDecoder()
            for row in rows {
                if !row.text.isEmpty {
                    MarkdownText.prewarm(row.text)
                }
                guard let json = row.attachmentsJSON,
                      let data = json.data(using: .utf8),
                      let atts = try? decoder.decode([StoredAttachment].self, from: data)
                else { continue }
                for att in atts where att.kind == "image" {
                    if let sha = att.sha256 { _ = ChatImageStore.shared.thumbnail(sha: sha) }
                }
            }
        }
    }
}
