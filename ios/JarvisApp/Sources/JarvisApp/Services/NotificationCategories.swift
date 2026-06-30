import UserNotifications

/// The single notification category for agent messages, carrying a text-input
/// "reply" action so the user can answer from the lock screen. Registered once
/// at launch; `LocalNotifier` stamps every agent notification with this category.
enum NotificationCategories {
    static let agentMessage = "agent-message"
    static let replyAction = "reply"
    static let summaryReady = "summary-ready"

    static func agentMessageCategory() -> UNNotificationCategory {
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: "Ответить",
            options: [],
            textInputButtonTitle: "Отправить",
            textInputPlaceholder: "Сообщение…"
        )
        return UNNotificationCategory(
            identifier: agentMessage,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
    }

    static func summaryReadyCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: summaryReady, actions: [], intentIdentifiers: [], options: [])
    }

    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories([
            agentMessageCategory(),
            summaryReadyCategory(),
        ])
    }
}
