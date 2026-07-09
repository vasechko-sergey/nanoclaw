import Foundation

/// Cache of the active agent's visible messages. The chat list shows only the
/// current agent's non-technical rows; filtering `ws.messages` is O(n) and
/// ChatView reads the result ~7× per body pass, so it is cached in `@State` and
/// recomputed only on a message-set or agent change (see
/// `ChatView.recomputeVisibleMessages`).
///
/// `version` bumps on EVERY recompute, and ChatView passes it to `MessageListView`
/// as the `messagesVersion` change-token. This is load-bearing for agent
/// switching: `active.active` changes one render BEFORE the `@State` cache is
/// refreshed (the refresh runs in `.onChange(of: active.active)`), so
/// `MessageListView`'s first post-switch render sees the NEW `agentId` with the
/// OLD messages and consumes its `agentChanged` fast-path signal. The corrected
/// messages arrive on the next render — and would be dropped by
/// `MessageListView`'s O(1) early-return (agent unchanged, and `ws.messagesVersion`
/// does NOT move on a pure agent switch) unless the token also moved. Tying
/// `version` to the recompute guarantees that second render is applied.
///
/// (Regression fix: passing `ws.messagesVersion` directly meant a pure agent
/// switch bumped no token, so the chat kept showing the PREVIOUS agent's
/// messages and only caught up on the *next* switch.)
struct VisibleMessageCache {
    private(set) var messages: [ChatMessage] = []
    private(set) var version: Int = 0

    /// Filter `all` to `agent`'s visible messages and bump `version`. Filtering
    /// semantics match the former `ChatView.computeVisibleMessages`: rows missing
    /// `agentId` are legacy jarvis traffic; comparison goes through
    /// `AgentIdentity(rawValue:)`; system-role rows are excluded (`isVisible`).
    mutating func recompute(from all: [ChatMessage], agent: AgentIdentity) {
        messages = all.filter { msg in
            guard msg.isVisible else { return false }
            let slug = msg.agentId ?? "jarvis"
            return AgentIdentity(rawValue: slug) == agent
        }
        version &+= 1
    }
}
