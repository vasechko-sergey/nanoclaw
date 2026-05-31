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
        guard let data = img.jpegData(compressionQuality: 0.85) else { return nil }
        return DraftAttachment(kind: .image, name: name, mimeType: "image/jpeg",
                               data: data, image: img)
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
