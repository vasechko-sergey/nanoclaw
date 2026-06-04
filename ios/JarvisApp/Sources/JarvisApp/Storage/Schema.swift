import Foundation
import GRDB

enum Schema {
    static func migrate(_ writer: any DatabaseWriter) throws {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE conversations (
                  id TEXT PRIMARY KEY,
                  title TEXT,
                  created_at INTEGER NOT NULL,
                  last_message_at INTEGER NOT NULL,
                  archived INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE messages (
                  id TEXT PRIMARY KEY,
                  conversation_id TEXT NOT NULL REFERENCES conversations(id),
                  dir TEXT NOT NULL CHECK (dir IN ('out','in')),
                  seq INTEGER,
                  text TEXT NOT NULL,
                  attachments_json TEXT,
                  context_json TEXT,
                  status TEXT NOT NULL,
                  failure_reason TEXT,
                  ts INTEGER NOT NULL,
                  server_ts INTEGER,
                  created_at INTEGER NOT NULL
                );
                CREATE INDEX idx_msg_conv_ts ON messages (conversation_id, ts);
                CREATE INDEX idx_msg_status ON messages (status);
                CREATE TABLE attachments (
                  id TEXT PRIMARY KEY,
                  message_id TEXT NOT NULL REFERENCES messages(id),
                  kind TEXT NOT NULL CHECK (kind IN ('image','file')),
                  name TEXT NOT NULL,
                  mime_type TEXT NOT NULL,
                  byte_size INTEGER NOT NULL,
                  local_path TEXT,
                  remote_id TEXT
                );
                CREATE TABLE cursors (
                  k TEXT PRIMARY KEY,
                  v INTEGER NOT NULL
                );
                CREATE TABLE inbound_dedup (
                  id TEXT PRIMARY KEY,
                  seq INTEGER NOT NULL,
                  received_at INTEGER NOT NULL
                );
            """)
        }
        // v2 retired the legacy file-based ConversationStore shim — moved
        // pin/active state into GRDB. v3 (below) then dropped grouping
        // entirely; this block stays as the migration audit trail.
        m.registerMigration("v2-conversation-meta") { db in
            try db.execute(sql: """
                ALTER TABLE conversations ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0;
                CREATE TABLE kv (
                  k TEXT PRIMARY KEY,
                  v TEXT
                );
            """)
        }
        m.registerMigration("v3-single-chat") { db in
            // Destructive: single timeline replaces grouped conversations.
            try db.execute(sql: """
                DROP TABLE IF EXISTS inbound_dedup;
                DROP TABLE IF EXISTS attachments;
                DROP TABLE IF EXISTS messages;
                DROP TABLE IF EXISTS conversations;
                DROP TABLE IF EXISTS kv;

                CREATE TABLE messages (
                  id            TEXT PRIMARY KEY,
                  dir           TEXT NOT NULL CHECK (dir IN ('out','in')),
                  seq           INTEGER,
                  text          TEXT NOT NULL,
                  attachments_json TEXT,
                  context_json  TEXT,
                  status        TEXT NOT NULL,
                  failure_reason TEXT,
                  ts            INTEGER NOT NULL,
                  server_ts     INTEGER,
                  created_at    INTEGER NOT NULL
                );
                CREATE INDEX idx_msg_ts ON messages (ts);
                CREATE INDEX idx_msg_status ON messages (status);

                CREATE TABLE attachments (
                  id           TEXT PRIMARY KEY,
                  message_id   TEXT NOT NULL REFERENCES messages(id),
                  kind         TEXT NOT NULL CHECK (kind IN ('image','file')),
                  name         TEXT NOT NULL,
                  mime_type    TEXT NOT NULL,
                  byte_size    INTEGER NOT NULL,
                  local_path   TEXT,
                  remote_id    TEXT
                );

                CREATE TABLE inbound_dedup (
                  id          TEXT PRIMARY KEY,
                  seq         INTEGER NOT NULL,
                  received_at INTEGER NOT NULL
                );
            """)
            // cursors table from v1 stays; it doesn't reference conversations.
        }
        try m.migrate(writer)
    }
}
