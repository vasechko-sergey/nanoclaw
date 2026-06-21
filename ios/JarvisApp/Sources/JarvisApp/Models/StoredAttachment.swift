import Foundation

/// Persistence shape stored in `messages.attachments_json`. A superset of the
/// metadata: image/file bytes live in `ChatImageStore` and are referenced by
/// `sha256`; audio voice notes (and legacy/un-migrated images) keep their bytes
/// inline in `bytes_base64`. Distinct from the wire type `V2.Attachment` (which
/// is pinned by the protocol fixture tests and must not gain local fields).
///
/// Synthesized `Codable` uses `encodeIfPresent` for optionals, so nil fields are
/// omitted on encode — and unknown keys (legacy `id`) are ignored on decode, so
/// this also decodes old `V2.Attachment`-shaped JSON.
struct StoredAttachment: Codable, Equatable {
    let kind: String          // "image" | "file" | "audio"
    let name: String
    let mime_type: String
    let byte_size: Int
    var sha256: String?       // set when bytes live in ChatImageStore
    var bytes_base64: String? // inline bytes: audio notes + legacy images
    var remote_id: String?

    /// Convert a wire attachment for storage. Image/file bytes are moved into
    /// `ChatImageStore` and replaced by a `sha256` ref; audio (and anything
    /// without inline bytes) is kept as-is. Does synchronous disk I/O for the
    /// image/file case — call off the main thread (all call sites run on the
    /// GRDB writer queue).
    static func from(_ a: V2.Attachment) -> StoredAttachment {
        if (a.kind == "image" || a.kind == "file"),
           let b64 = a.bytes_base64, let data = Data(base64Encoded: b64) {
            let sha = ChatImageStore.shared.write(data)
            return StoredAttachment(kind: a.kind, name: a.name, mime_type: a.mime_type,
                                    byte_size: a.byte_size, sha256: sha,
                                    bytes_base64: nil, remote_id: a.remote_id)
        }
        return StoredAttachment(kind: a.kind, name: a.name, mime_type: a.mime_type,
                                byte_size: a.byte_size, sha256: nil,
                                bytes_base64: a.bytes_base64, remote_id: a.remote_id)
    }
}
