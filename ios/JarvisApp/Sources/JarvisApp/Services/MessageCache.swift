import Foundation
import UIKit

private struct CachedMessage: Codable {
    let id: String
    let role: String          // "user" | "assistant" | "system"
    let kind: String          // "text" | "image" | "file" | "action" | "status"
    let text: String?
    let imageFile: String?
    let filename: String?
    let timestamp: Date

    // File-specific
    let fileName: String?
    let fileSize: Int64?
    let fileMimeType: String?
    let fileUrl: String?

    // Action-specific
    let buttons: [CachedButton]?
    let actionAnswered: Bool?
    let actionSelectedId: String?

    // Status-specific
    let statusLevel: String?
    let statusKind: String?

    let deliveryStatus: String?   // "sending"|"sent"|"delivered"|"failed"|nil
}

private struct CachedButton: Codable {
    let id: String
    let label: String
    let style: String
}

enum MessageCache {
    static let maxMessages = 150

    static func load(from dir: URL) -> [ChatMessage] {
        let indexURL = dir.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode([CachedMessage].self, from: data)
        else { return [] }

        return cached.compactMap { cm in
            let role: ChatMessage.Role
            switch cm.role {
            case "user":      role = .user
            case "system":    role = .system
            default:          role = .assistant
            }

            let restoredStatus: DeliveryStatus = {
                switch cm.deliveryStatus {
                case "sent": return .sent
                case "failed": return .failed
                default: return .delivered  // sending/nil → delivered (past session = done)
                }
            }()

            switch cm.kind {
            case "text":
                guard let t = cm.text else { return nil }
                var msg = ChatMessage.text(cm.id, role: role, text: t, timestamp: cm.timestamp)
                msg.deliveryStatus = restoredStatus
                return msg

            case "image":
                guard let file = cm.imageFile, let fname = cm.filename else { return nil }
                let url = dir.appendingPathComponent(file)
                if let d = try? Data(contentsOf: url), let img = UIImage(data: d) {
                    var msg = ChatMessage.image(cm.id, role: role, image: img, filename: fname, timestamp: cm.timestamp)
                    msg.deliveryStatus = restoredStatus
                    return msg
                }
                // Image file missing/corrupt — keep the message as a placeholder
                var msg = ChatMessage.text(cm.id, role: role, text: "🖼 \(fname) (изображение недоступно)", timestamp: cm.timestamp)
                msg.deliveryStatus = restoredStatus
                return msg

            case "file":
                guard let name = cm.fileName else { return nil }
                let info = FileInfo(
                    name: name,
                    size: cm.fileSize ?? 0,
                    mimeType: cm.fileMimeType ?? "application/octet-stream",
                    url: cm.fileUrl,
                    thumbnail: nil
                )
                var msg = ChatMessage.file(cm.id, role: role, info: info, timestamp: cm.timestamp)
                msg.deliveryStatus = restoredStatus
                return msg

            case "action":
                guard let text = cm.text else { return nil }
                let buttons = (cm.buttons ?? []).map { b in
                    ActionButton(id: b.id, label: b.label, style: ActionButton.Style(rawValue: b.style) ?? .primary)
                }
                var actionInfo = ActionInfo(text: text, buttons: buttons)
                actionInfo.answered = cm.actionAnswered ?? false
                actionInfo.selectedId = cm.actionSelectedId
                var msg = ChatMessage(id: cm.id, role: role, content: .action(actionInfo), timestamp: cm.timestamp)
                msg.deliveryStatus = restoredStatus
                return msg

            case "status":
                guard let text = cm.text else { return nil }
                let level = StatusInfo.Level(rawValue: cm.statusLevel ?? "info") ?? .info
                var msg = ChatMessage.status(cm.id, text: text, level: level, kind: cm.statusKind, timestamp: cm.timestamp)
                msg.deliveryStatus = restoredStatus
                return msg

            default:
                return nil
            }
        }
    }

    static func save(_ messages: [ChatMessage], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexURL = dir.appendingPathComponent("index.json")

        let recent = messages.suffix(maxMessages)
        let cached: [CachedMessage] = recent.map { msg in
            let role: String
            switch msg.role {
            case .user:      role = "user"
            case .assistant: role = "assistant"
            case .system:    role = "system"
            }

            switch msg.content {
            case .text(let t):
                return CachedMessage(id: msg.id, role: role, kind: "text",
                                     text: t, imageFile: nil, filename: nil, timestamp: msg.timestamp,
                                     fileName: nil, fileSize: nil, fileMimeType: nil, fileUrl: nil,
                                     buttons: nil, actionAnswered: nil, actionSelectedId: nil,
                                     statusLevel: nil, statusKind: nil,
                                     deliveryStatus: msg.deliveryStatus.rawValue)

            case .image(let img, let fname):
                let file = msg.id + ".jpg"
                if let d = img.jpegData(compressionQuality: 0.85) {
                    do { try d.write(to: dir.appendingPathComponent(file), options: .atomic) }
                    catch { Log.warn(.cache, "image write failed for \(file): \(error)") }
                }
                return CachedMessage(id: msg.id, role: role, kind: "image",
                                     text: nil, imageFile: file, filename: fname, timestamp: msg.timestamp,
                                     fileName: nil, fileSize: nil, fileMimeType: nil, fileUrl: nil,
                                     buttons: nil, actionAnswered: nil, actionSelectedId: nil,
                                     statusLevel: nil, statusKind: nil,
                                     deliveryStatus: msg.deliveryStatus.rawValue)

            case .file(let info):
                return CachedMessage(id: msg.id, role: role, kind: "file",
                                     text: nil, imageFile: nil, filename: nil, timestamp: msg.timestamp,
                                     fileName: info.name, fileSize: info.size, fileMimeType: info.mimeType, fileUrl: info.url,
                                     buttons: nil, actionAnswered: nil, actionSelectedId: nil,
                                     statusLevel: nil, statusKind: nil,
                                     deliveryStatus: msg.deliveryStatus.rawValue)

            case .action(let info):
                let buttons = info.buttons.map { CachedButton(id: $0.id, label: $0.label, style: $0.style.rawValue) }
                return CachedMessage(id: msg.id, role: role, kind: "action",
                                     text: info.text, imageFile: nil, filename: nil, timestamp: msg.timestamp,
                                     fileName: nil, fileSize: nil, fileMimeType: nil, fileUrl: nil,
                                     buttons: buttons, actionAnswered: info.answered, actionSelectedId: info.selectedId,
                                     statusLevel: nil, statusKind: nil,
                                     deliveryStatus: msg.deliveryStatus.rawValue)

            case .status(let info):
                return CachedMessage(id: msg.id, role: role, kind: "status",
                                     text: info.text, imageFile: nil, filename: nil, timestamp: msg.timestamp,
                                     fileName: nil, fileSize: nil, fileMimeType: nil, fileUrl: nil,
                                     buttons: nil, actionAnswered: nil, actionSelectedId: nil,
                                     statusLevel: info.level.rawValue, statusKind: info.kind,
                                     deliveryStatus: msg.deliveryStatus.rawValue)
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(cached) {
            // Atomic write (temp + rename) so a crash mid-write can't corrupt the
            // whole history index and lose every message.
            do { try data.write(to: indexURL, options: .atomic) }
            catch { Log.error(.cache, "index write failed: \(error)") }
        }

        pruneOrphanImages(in: dir, keeping: Set(recent.compactMap { msg -> String? in
            if case .image = msg.content { return msg.id + ".jpg" }
            return nil
        }))
    }

    private static func pruneOrphanImages(in dir: URL, keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where f.hasSuffix(".jpg") && !names.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }
}
