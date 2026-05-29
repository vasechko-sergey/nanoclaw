import UIKit
import AVFoundation

/// A media item the user picked but hasn't sent yet. Held in the input bar's
/// draft list and rendered as a preview chip. On send it is base64-encoded into
/// the WebSocket `message.attachments` array.
struct DraftAttachment: Identifiable, Equatable {
    let id = UUID()
    let kind: Kind
    let name: String
    let mimeType: String
    let data: Data
    /// Decoded preview for image attachments (nil for generic files).
    /// For video attachments this holds the first-frame thumbnail too so the
    /// existing chip rendering path keeps working without a special case.
    let image: UIImage?
    /// First-frame thumbnail for video attachments. Nil for image/file.
    let thumbnail: UIImage?
    /// Video duration in seconds. Nil for image/file.
    let duration: TimeInterval?

    enum Kind { case image, video, file }

    enum VideoError: Error, Equatable {
        case tooLarge
    }

    /// Hard cap on raw video bytes before base64 expansion. 100 MB matches the
    /// spec and keeps WebSocket payloads sane.
    static let maxVideoBytes = 100 * 1024 * 1024

    var size: Int { data.count }

    static func == (lhs: DraftAttachment, rhs: DraftAttachment) -> Bool { lhs.id == rhs.id }

    /// Throwing size check usable from both factories and tests.
    static func checkVideoSize(_ data: Data) throws {
        if data.count > maxVideoBytes { throw VideoError.tooLarge }
    }

    // MARK: – Image / file factories (existing)

    static func image(_ img: UIImage, name: String) -> DraftAttachment? {
        guard let data = img.jpegData(compressionQuality: 0.85) else { return nil }
        return DraftAttachment(kind: .image, name: name, mimeType: "image/jpeg",
                               data: data, image: img, thumbnail: nil, duration: nil)
    }

    static func file(data: Data, name: String, mimeType: String) -> DraftAttachment {
        let img = mimeType.hasPrefix("image/") ? UIImage(data: data) : nil
        return DraftAttachment(kind: img != nil ? .image : .file,
                               name: name, mimeType: mimeType,
                               data: data, image: img, thumbnail: nil, duration: nil)
    }

    // MARK: – Video factories

    /// Sync factory — used by tests and by the async loader after the
    /// thumbnail/duration have been generated.
    static func video(name: String,
                      thumbnail: UIImage,
                      duration: TimeInterval,
                      data: Data,
                      mimeType: String) -> DraftAttachment {
        return DraftAttachment(kind: .video, name: name, mimeType: mimeType,
                               data: data, image: thumbnail,
                               thumbnail: thumbnail, duration: duration)
    }

    /// Async factory used by the picker and camera. Loads the file bytes,
    /// asserts the size cap, then pulls a 0.1s thumbnail and the duration via
    /// AVFoundation. On size overflow, throws `VideoError.tooLarge`.
    static func video(from url: URL) async throws -> DraftAttachment {
        let data = try Data(contentsOf: url)
        try checkVideoSize(data)

        let asset = AVURLAsset(url: url)
        let durationCmTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationCmTime)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let cgImage = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        let thumb = UIImage(cgImage: cgImage)

        let mime = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        let displayName = "video-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension)"

        return DraftAttachment.video(name: displayName, thumbnail: thumb,
                                     duration: duration, data: data, mimeType: mime)
    }

    /// Wire shape the server's `extractAttachmentFiles` expects:
    /// { name, mimeType, data(base64), size, (duration?) }.
    var payload: [String: Any] {
        var p: [String: Any] = ["name": name, "mimeType": mimeType,
                                "data": data.base64EncodedString(), "size": size]
        if let duration { p["duration"] = Int(duration) }
        return p
    }
}
