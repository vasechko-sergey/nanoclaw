import Foundation

/// Outbound (user-sent) message status transitions: queued → sending → sent | failed.
/// Inbound (agent-sent) message status transitions: new → delivered → read.
/// Composing is UI-only and not persisted.
enum StatusV2Transitions {
    static func canTransition(from a: MessageStatus, to b: MessageStatus) -> Bool {
        switch (a, b) {
        case (.queued, .sending): return true
        case (.sending, .sent): return true
        case (.sending, .queued): return true   // reconnect reset
        case (.queued, .failed), (.sending, .failed): return true
        case (.failed, .queued): return true    // user retry
        case (.new, .delivered): return true
        case (.delivered, .read): return true
        case (.new, .read): return true         // shortcut: foreground arrival
        case (.sent, .delivered): return true   // legacy compatibility
        case (.sent, .read): return true
        default: return a == b                  // no-op
        }
    }
}
