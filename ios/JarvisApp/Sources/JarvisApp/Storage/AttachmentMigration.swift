import Foundation
import GRDB

/// One-shot data migration: rewrite legacy `attachments_json` rows that still
/// carry inline image/file `bytes_base64` into `ChatImageStore` refs. Idempotent
/// — already-migrated rows (sha256 set, no inline bytes) are skipped. Safe to
/// run on every launch behind a UserDefaults flag; correctness does not depend
/// on it (the read path still renders un-migrated rows), but it reclaims the
/// base64 bloat and makes old images sharp on tap.
enum AttachmentMigration {
    static func run(writer: any DatabaseWriter, store: ChatImageStore) throws {
        try writer.write { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT id, attachments_json FROM messages WHERE attachments_json IS NOT NULL")
            for row in rows {
                guard let json: String = row["attachments_json"],
                      let data = json.data(using: .utf8),
                      var atts = try? JSONDecoder().decode([StoredAttachment].self, from: data)
                else { continue }
                var changed = false
                for i in atts.indices {
                    guard atts[i].kind == "image" || atts[i].kind == "file" else { continue }
                    guard atts[i].sha256 == nil,
                          let b64 = atts[i].bytes_base64,
                          let bytes = Data(base64Encoded: b64) else { continue }
                    let sha = store.write(bytes)
                    // Only drop the inline bytes if the file actually landed —
                    // otherwise a failed disk write would leave a row pointing at
                    // a missing file with no copy of the bytes. Leaving it inline
                    // lets a later run retry.
                    guard store.has(sha: sha) else { continue }
                    atts[i].sha256 = sha
                    atts[i].bytes_base64 = nil
                    changed = true
                }
                if changed, let newJSON = String(data: try JSONEncoder().encode(atts), encoding: .utf8) {
                    let id: String = row["id"]
                    try db.execute(sql: "UPDATE messages SET attachments_json=? WHERE id=?",
                                   arguments: [newJSON, id])
                }
            }
        }
    }
}
