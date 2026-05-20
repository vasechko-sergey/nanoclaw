import Foundation

struct ChatMessage: Identifiable {
    let id: String
    let role: Role
    let text: String
    let timestamp: Date

    enum Role { case user, assistant }
}
