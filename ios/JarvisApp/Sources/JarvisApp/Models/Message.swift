import Foundation
import UIKit

struct ChatMessage: Identifiable {
    let id: String
    let role: Role
    let content: Content
    let timestamp: Date

    enum Role { case user, assistant }

    enum Content {
        case text(String)
        case image(UIImage, filename: String)
    }

    var text: String {
        if case .text(let t) = content { return t }
        return ""
    }

    static func text(_ id: String, role: Role, text: String, timestamp: Date) -> ChatMessage {
        ChatMessage(id: id, role: role, content: .text(text), timestamp: timestamp)
    }

    static func image(_ id: String, role: Role, image: UIImage, filename: String, timestamp: Date) -> ChatMessage {
        ChatMessage(id: id, role: role, content: .image(image, filename: filename), timestamp: timestamp)
    }
}
