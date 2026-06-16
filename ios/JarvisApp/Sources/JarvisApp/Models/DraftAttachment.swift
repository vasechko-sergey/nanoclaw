import UIKit

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
    let image: UIImage?

    enum Kind { case image, file }

    var size: Int { data.count }

    static func == (lhs: DraftAttachment, rhs: DraftAttachment) -> Bool { lhs.id == rhs.id }

    // MARK: – Image / file factories

    static func image(_ img: UIImage, name: String) -> DraftAttachment? {
        // Cap the longest edge before encoding — a full-res phone photo is
        // multi-MB and gets base64'd into the message row + WS payload + then
        // decoded on every timeline rebuild. 1600px keeps plenty of quality.
        let scaled = downscaled(img, maxEdge: 1600)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        return DraftAttachment(kind: .image, name: name, mimeType: "image/jpeg",
                               data: data, image: scaled)
    }

    private static func downscaled(_ img: UIImage, maxEdge: CGFloat) -> UIImage {
        let longest = max(img.size.width, img.size.height)
        guard longest > maxEdge, longest > 0 else { return img }
        let scale = maxEdge / longest
        let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    static func file(data: Data, name: String, mimeType: String) -> DraftAttachment {
        let img = mimeType.hasPrefix("image/") ? UIImage(data: data) : nil
        return DraftAttachment(kind: img != nil ? .image : .file,
                               name: name, mimeType: mimeType,
                               data: data, image: img)
    }

    /// Wire shape the server's `extractAttachmentFiles` expects:
    /// { name, mimeType, data(base64), size }.
    var payload: [String: Any] {
        return ["name": name, "mimeType": mimeType,
                "data": data.base64EncodedString(), "size": size]
    }
}
