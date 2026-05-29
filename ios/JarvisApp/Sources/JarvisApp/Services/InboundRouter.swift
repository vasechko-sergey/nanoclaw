import Foundation
import UIKit

// MARK: - InboundRouter
//
// Owns "how does an inbound JSON envelope become a state change."
// Type-dispatch + active-vs-background conversation routing.
//
// Adding a new server→iOS message type means editing this file and adding
// any new delegate hook — not touching WebSocketClient.
//
// Connection-establishment messages (`auth_ok`) stay in WebSocketClient
// because they're tightly coupled to transport bootstrap (start heartbeat,
// re-flush outbox, forward queued APNs token). Everything content-shaped
// lives here.

@MainActor
protocol InboundRouterDelegate: AnyObject {
    var activeConversationId: UUID? { get }
    var messages: [ChatMessage] { get set }

    func setTyping(_ value: Bool)
    func handleMessageAck(clientMessageId: String)
    func sendContextResponse(requestId: String, context: [String: Any])
    func sendMessageDelivered(_ messageId: String, conversationId: UUID?)

    func notifyAssistantArrival()
    func notifyMessagesChanged(_ messages: [ChatMessage])
    func notifySpeakableText(_ text: String)
    func notifyBackgroundMessage(conversationId: UUID, message: ChatMessage)

    func gatherContext(fields: [String]) -> [String: Any]

    func recordAssistantTimestamp()
    func setThinkingDetail(_ text: String?)
    func scheduleThinkingDetailAutoClear(for text: String)
}

@MainActor
final class InboundRouter {
    weak var delegate: InboundRouterDelegate?

    /// Returns true if the envelope was consumed by the router. `auth_ok` is
    /// the only `false` case — the caller handles it.
    @discardableResult
    func dispatch(_ obj: [String: Any]) -> Bool {
        let t = obj["type"] as? String

        // Caller (WebSocketClient) handles auth_ok — it's coupled to transport
        // bootstrap (heartbeat start, queued APNs).
        if t == "auth_ok" { return false }

        if t == "typing_start" {
            delegate?.setTyping(true)
            return true
        }
        if t == "typing_stop" {
            delegate?.setTyping(false)
            return true
        }

        if t == "feedback_ack" {
            return true  // no UI action needed
        }

        if t == "message_ack",
           let clientMsgId = obj["clientMessageId"] as? String {
            delegate?.handleMessageAck(clientMessageId: clientMsgId)
            return true
        }

        if t == "context_request" {
            let fields = obj["fields"] as? [String] ?? []
            let requestId = obj["requestId"] as? String ?? ""
            let ctx = delegate?.gatherContext(fields: fields) ?? [:]
            delegate?.sendContextResponse(requestId: requestId, context: ctx)
            return true
        }

        let convId = (obj["conversationId"] as? String).flatMap(UUID.init(uuidString:))

        if t == "message",
           let text = obj["text"] as? String,
           let id   = obj["id"]   as? String {
            route(.text(id, role: .assistant, text: text, timestamp: Date()), convId: convId)
            return true
        }

        if t == "image",
           let b64      = obj["data"]     as? String,
           let id       = obj["id"]       as? String,
           let filename = obj["filename"] as? String,
           let imgData  = Data(base64Encoded: b64),
           let image    = UIImage(data: imgData) {
            route(.image(id, role: .assistant, image: image, filename: filename, timestamp: Date()), convId: convId)
            return true
        }

        if t == "file",
           let id   = obj["id"]   as? String,
           let name = obj["name"] as? String {
            let info = FileInfo(
                name: name,
                size: obj["size"] as? Int64 ?? 0,
                mimeType: obj["mimeType"] as? String ?? "application/octet-stream",
                url: obj["url"] as? String,
                thumbnail: nil
            )
            route(.file(id, role: .assistant, info: info, timestamp: Date()), convId: convId)
            return true
        }

        if t == "action",
           let id   = obj["id"]   as? String,
           let text = obj["text"] as? String,
           let btns = obj["buttons"] as? [[String: Any]] {
            let buttons = btns.compactMap { b -> ActionButton? in
                guard let bid = b["id"] as? String, let label = b["label"] as? String else { return nil }
                let style = ActionButton.Style(rawValue: b["style"] as? String ?? "primary") ?? .primary
                return ActionButton(id: bid, label: label, style: style)
            }
            route(.action(id, text: text, buttons: buttons, timestamp: Date()), convId: convId)
            return true
        }

        if t == "status",
           let text = obj["text"] as? String {
            let id = obj["id"] as? String ?? UUID().uuidString
            let level = StatusInfo.Level(rawValue: obj["level"] as? String ?? "info") ?? .info
            let kind = obj["kind"] as? String
            route(.status(id, text: text, level: level, kind: kind, timestamp: Date()), convId: convId)
            return true
        }

        // Unknown type — silently drop.
        return true
    }

    /// Route a server-produced message to the active conversation (mutating
    /// the messages array, firing delivery receipts, etc.) or to a background
    /// conversation's store.
    private func route(_ message: ChatMessage, convId: UUID?) {
        guard let delegate else { return }
        delegate.notifyAssistantArrival()

        let activeId = delegate.activeConversationId
        if convId == nil || convId == activeId {
            delegate.setTyping(false)
            // Dedup: the host re-flushes queued messages on reconnect, so the
            // same id can arrive twice. Skip if already present.
            if delegate.messages.contains(where: { $0.id == message.id }) { return }
            if message.role == .assistant {
                delegate.sendMessageDelivered(message.id, conversationId: activeId)
            }
            delegate.messages.append(message)
            delegate.notifyMessagesChanged(delegate.messages)
            if message.role == .assistant {
                delegate.recordAssistantTimestamp()
                delegate.setThinkingDetail(nil)
            }
            if case .status(let info) = message.content, info.kind == "system" {
                delegate.setThinkingDetail(info.text)
                delegate.scheduleThinkingDetailAutoClear(for: info.text)
            }
            if message.role == .assistant, case .text(let t) = message.content {
                delegate.notifySpeakableText(t)
            }
        } else {
            delegate.notifyBackgroundMessage(conversationId: convId!, message: message)
        }
    }
}
