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
    private let isMuted: (String) -> Bool
    private let inQuietHours: () -> Bool
    private let isSummaryEnabled: () -> Bool
    private let storeLock = NSLock()
    private var _store: ConversationStoreV2?
    private var store: ConversationStoreV2? { storeLock.withLock { _store } }

    init(
        center: NotificationScheduling = UNUserNotificationCenter.current(),
        isForeground: @escaping () -> Bool = { AppForegroundState.isActive },
        isEnabled: @escaping () -> Bool = {
            // Mirrors @AppStorage("notificationsEnabled") default = true.
            UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        },
        isMuted: @escaping (String) -> Bool = { agentId in
            MutedAgents.decode(UserDefaults.standard.string(forKey: "mutedAgents") ?? "[]").contains(agentId)
        },
        inQuietHours: @escaping () -> Bool = {
            let d = UserDefaults.standard
            let enabled = d.object(forKey: "quietHoursEnabled") as? Bool ?? false
            let start = d.object(forKey: "quietStartMinutes") as? Int ?? 1380
            let end = d.object(forKey: "quietEndMinutes") as? Int ?? 480
            let cal = Calendar.current
            let now = Date()
            let t = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
            return QuietHours.contains(minutes: t, start: start, end: end, enabled: enabled)
        },
        isSummaryEnabled: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: "summaryNotificationsEnabled") as? Bool ?? true
        }
    ) {
        self.center = center
        self.isForeground = isForeground
        self.isEnabled = isEnabled
        self.isMuted = isMuted
        self.inQuietHours = inQuietHours
        self.isSummaryEnabled = isSummaryEnabled
    }

    /// Wire the dedup store. Called once at app init (foreground or background
    /// launch) from `AppCoordinator`. Until configured, `raise` is a safe no-op.
    func configure(store: ConversationStoreV2) {
        storeLock.withLock { _store = store }
    }

    func raise(id: String, agentId: String, text: String, seq: Int = 0) {
        guard !isForeground() else { return }   // already on screen
        guard isEnabled() else { return }
        guard !isMuted(agentId) else { return }
        guard !inQuietHours() else { return }
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

    /// Raises the «Сводка готова» morning summary notification.
    /// Gating: not foreground + global enable + isSummaryEnabled + not quiet hours + dedup by id.
    /// Per-agent mute is intentionally NOT checked — this is a cross-agent dashboard summary.
    /// `body` is composed host-side (correct Russian plural via `pluralRu`) and passed
    /// through verbatim on BOTH the live WS path and the background pull path.
    func raiseSummaryReady(id: String, body: String, agentId: String) {
        guard !isForeground() else { return }
        guard isEnabled() else { return }
        guard isSummaryEnabled() else { return }   // dedicated «Сводка» toggle (not per-agent mute)
        guard !inQuietHours() else { return }
        guard let store else { return }
        if (try? store.notifiedSeen(id: id)) == true { return }

        let content = UNMutableNotificationContent()
        content.title = "Сводка"
        content.body = body
        content.sound = .default
        content.threadIdentifier = "summary"
        content.categoryIdentifier = NotificationCategories.summaryReady
        content.userInfo = ["summary": true, "agentId": agentId, "msgId": id]

        let req = UNNotificationRequest(identifier: "summary-\(id)", content: content, trigger: nil)
        center.schedule(req)
        try? store.recordNotified(id: id, seq: 0)
    }
}
