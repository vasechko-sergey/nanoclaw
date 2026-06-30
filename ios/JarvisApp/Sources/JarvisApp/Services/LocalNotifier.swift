import Foundation
import UserNotifications

/// Seam over `UNUserNotificationCenter` so tests can record scheduled requests.
protocol NotificationScheduling: AnyObject {
    func schedule(_ request: UNNotificationRequest)
}

extension UNUserNotificationCenter: NotificationScheduling {
    func schedule(_ request: UNNotificationRequest) {
        add(request, withCompletionHandler: nil)
    }
}

/// Raises agent-message local notifications. No APNs — these are on-device
/// notifications fired while the app is alive (live WS insert) or on a
/// background self-wake pull. Gated on: app not foreground-active, the user
/// setting, and a per-id dedup against `inbound_dedup.notified_at`.
final class LocalNotifier {
    static let shared = LocalNotifier()

    private let center: NotificationScheduling
    private let isForeground: () -> Bool
    private let isEnabled: () -> Bool
    private let storeLock = NSLock()
    private var _store: ConversationStoreV2?
    private var store: ConversationStoreV2? { storeLock.withLock { _store } }

    init(
        center: NotificationScheduling = UNUserNotificationCenter.current(),
        isForeground: @escaping () -> Bool = { AppForegroundState.isActive },
        isEnabled: @escaping () -> Bool = {
            // Mirrors @AppStorage("notificationsEnabled") default = true.
            UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        }
    ) {
        self.center = center
        self.isForeground = isForeground
        self.isEnabled = isEnabled
    }

    /// Wire the dedup store. Called once at app init (foreground or background
    /// launch) from `AppCoordinator`. Until configured, `raise` is a safe no-op.
    func configure(store: ConversationStoreV2) {
        storeLock.withLock { _store = store }
    }

    func raise(id: String, agentId: String, text: String, seq: Int = 0) {
        guard !isForeground() else { return }   // already on screen
        guard isEnabled() else { return }
        guard let store else { return }
        // A DB error → treated as not-yet-notified → we re-notify (prefer a
        // duplicate banner over silently suppressing a real message).
        if (try? store.notifiedSeen(id: id)) == true { return }

        let content = UNMutableNotificationContent()
        content.title = AgentIdentity(rawValue: agentId)?.displayName ?? "Jarvis"
        content.body = String(text.prefix(160))
        content.sound = .default
        content.threadIdentifier = agentId
        content.categoryIdentifier = NotificationCategories.agentMessage
        content.userInfo = ["agentId": agentId, "msgId": id]

        // nil trigger → delivered immediately. Identifier keyed by message id so
        // a repeat (belt-and-suspenders vs the dedup) replaces rather than dups.
        let req = UNNotificationRequest(identifier: "msg-\(id)", content: content, trigger: nil)
        center.schedule(req)
        try? store.recordNotified(id: id, seq: seq)
    }
}
