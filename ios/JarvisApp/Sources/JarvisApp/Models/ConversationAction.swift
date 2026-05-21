import Foundation

enum ConversationAction {
    case newChat
    case newChatWithContext(String)
    case open(Conversation)
}
