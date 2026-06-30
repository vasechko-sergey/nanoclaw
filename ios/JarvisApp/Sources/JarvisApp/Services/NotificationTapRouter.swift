import UserNotifications

enum NotificationTapTarget: Equatable {
    case reply(agentId: String, text: String)
    case openSummaryBoard
    case openAgentChat(AgentIdentity)
    case none
}

enum NotificationTapRouter {
    static func route(
        categoryId: String,
        actionId: String,
        replyText: String?,
        userInfo: [AnyHashable: Any]
    ) -> NotificationTapTarget {
        if actionId == NotificationCategories.replyAction, let text = replyText {
            let agentId = userInfo["agentId"] as? String ?? "jarvis"
            return .reply(agentId: agentId, text: text)
        }
        switch categoryId {
        case NotificationCategories.summaryReady:
            return .openSummaryBoard
        case NotificationCategories.agentMessage:
            let slug = userInfo["agentId"] as? String ?? "jarvis"
            if let agent = AgentIdentity(rawValue: slug) { return .openAgentChat(agent) }
            return .none
        default:
            return .none
        }
    }
}
