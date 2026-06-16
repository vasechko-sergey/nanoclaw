import Foundation
import UIKit

// MARK: – Supporting types

struct FileInfo: Equatable {
    let name: String
    let size: Int64        // bytes
    let mimeType: String
    let url: String?       // download URL
    let thumbnail: UIImage?
}

struct ActionButton: Identifiable, Equatable {
    let id: String
    let label: String
    let style: Style

    enum Style: String { case primary, danger, secondary }

    static func == (lhs: ActionButton, rhs: ActionButton) -> Bool {
        lhs.id == rhs.id && lhs.label == rhs.label && lhs.style == rhs.style
    }
}

struct ActionInfo: Equatable {
    let text: String
    let buttons: [ActionButton]
    var answered: Bool = false      // true after user taps a button
    var selectedId: String? = nil   // which button was tapped
}

struct StatusInfo: Equatable {
    let text: String
    let level: Level
    var kind: String? = nil   // "system" | "cost" | "health" | "alert" — nil → icon from level

    enum Level: String { case info, warning, error }
}

enum DeliveryStatus: String, Codable {
    case sending    // WS.send() called, no callback yet
    case sent       // WS send callback returned no error
    case delivered  // server sent message_ack
    case failed     // WS send callback returned error
}

// MARK: – ChatMessage

struct ChatMessage: Identifiable {
    let id: String
    let role: Role
    let content: Content
    let timestamp: Date
    var deliveryStatus: DeliveryStatus = .delivered
    /// Matches `AgentIdentity.rawValue` and the `messages.agent_id` storage
    /// column. `nil` is treated as legacy jarvis traffic by `ChatView` so
    /// pre-T7 rows still render under the Jarvis chip.
    var agentId: String? = nil

    enum Role { case user, assistant, system }

    enum Content {
        case text(String)
        case image(UIImage, filename: String)
        case file(FileInfo)
        case audio(FileInfo)   // server-rendered voice note (kind=="audio" or mime audio/*)
        case action(ActionInfo)
        case status(StatusInfo)
    }

    // Convenience accessors

    var text: String {
        switch content {
        case .text(let t): return t
        case .action(let a): return a.text
        case .status(let s): return s.text
        case .audio(let f): return f.name
        default: return ""
        }
    }

    /// The audio FileInfo if this message carries a server voice note.
    var audioInfo: FileInfo? {
        if case .audio(let f) = content { return f }
        return nil
    }

    var isVisible: Bool {
        // Status messages are visible; system role is used for non-visible technical messages
        switch content {
        case .status: return true
        default: return role != .system
        }
    }

    // MARK: – Factory methods

    static func text(_ id: String, role: Role, text: String, timestamp: Date) -> ChatMessage {
        ChatMessage(id: id, role: role, content: .text(text), timestamp: timestamp)
    }

    static func image(_ id: String, role: Role, image: UIImage, filename: String, timestamp: Date) -> ChatMessage {
        ChatMessage(id: id, role: role, content: .image(image, filename: filename), timestamp: timestamp)
    }

    static func file(_ id: String, role: Role, info: FileInfo, timestamp: Date) -> ChatMessage {
        ChatMessage(id: id, role: role, content: .file(info), timestamp: timestamp)
    }

    static func action(_ id: String, text: String, buttons: [ActionButton], timestamp: Date) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: .action(ActionInfo(text: text, buttons: buttons)), timestamp: timestamp)
    }

    static func status(_ id: String, text: String, level: StatusInfo.Level, kind: String? = nil, timestamp: Date) -> ChatMessage {
        ChatMessage(id: id, role: .system, content: .status(StatusInfo(text: text, level: level, kind: kind)), timestamp: timestamp)
    }
}
