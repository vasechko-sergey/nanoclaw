import Foundation
import UIKit

private struct CachedMessage: Codable {
    let id: String
    let role: String
    let kind: String
    let text: String?
    let imageFile: String?
    let filename: String?
    let timestamp: Date
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
            let role: ChatMessage.Role = cm.role == "user" ? .user : .assistant
            switch cm.kind {
            case "text":
                guard let t = cm.text else { return nil }
                return .text(cm.id, role: role, text: t, timestamp: cm.timestamp)
            case "image":
                guard let file = cm.imageFile, let fname = cm.filename else { return nil }
                let url = dir.appendingPathComponent(file)
                guard let d = try? Data(contentsOf: url), let img = UIImage(data: d) else { return nil }
                return .image(cm.id, role: role, image: img, filename: fname, timestamp: cm.timestamp)
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
            let role = msg.role == .user ? "user" : "assistant"
            switch msg.content {
            case .text(let t):
                return CachedMessage(id: msg.id, role: role, kind: "text",
                                     text: t, imageFile: nil, filename: nil, timestamp: msg.timestamp)
            case .image(let img, let fname):
                let file = msg.id + ".jpg"
                if let d = img.jpegData(compressionQuality: 0.85) {
                    try? d.write(to: dir.appendingPathComponent(file))
                }
                return CachedMessage(id: msg.id, role: role, kind: "image",
                                     text: nil, imageFile: file, filename: fname, timestamp: msg.timestamp)
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(cached) {
            try? data.write(to: indexURL)
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
