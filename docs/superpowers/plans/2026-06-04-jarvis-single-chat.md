# Jarvis Single-Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip multi-conversation infra from the Jarvis iOS app; one continuous timeline backed by GRDB, pinned to `thread_id="ios:default"`. Server side `src/channels/ios-app/v2/*` is untouched.

**Architecture:** Drop the `conversations` table, the `ConversationStore` shim, and all drawer/list/pin/archive/active-id concepts. Keep `ConversationStoreV2` as the GRDB transport layer (queueing, dedup, cursors, message rows) but trim its API to be conversation-agnostic. UI replaces `ConversationStore`'s observable surface with a thin `MessageTimeline` wrapper that exposes `messages: [Message]` driven by a `ValueObservation` over the trimmed schema.

**Tech Stack:** Swift 5, SwiftUI, GRDB, `xcodegen`. Source of truth for the Xcode project lives in `ios/JarvisApp/project.yml`.

---

## File Structure

**Created:**
- `ios/JarvisApp/Sources/JarvisApp/Storage/MessageTimeline.swift` — `@Observable` UI-facing wrapper around `ConversationStoreV2`. Exposes `messages: [Message]` via `ValueObservation`, drives prune.

**Modified:**
- `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift` — adds `v3-single-chat` migration.
- `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift` — drop conversation methods; drop `conversation_id` from message methods; add `observeMessages` + `prune`.
- `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift` — `store: MessageTimeline`; drop `handleAction`, drop `openConversation`.
- `ios/JarvisApp/Sources/JarvisApp/Services/AppV2Bootstrap.swift` — return `MessageTimeline` instead of `ConversationStore`.
- `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift` — drop `conversationId` property + threading; always emit `thread_id="ios:default"`; drop `sendNewConversation`, `reloadActiveConversation`.
- `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` — drop `row.conversationId` usage.
- `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` — drop leading drawer + `ConversationAction` callbacks; static title.
- `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` — drop leading drawer + new-chat path.
- `ios/JarvisApp/Sources/JarvisApp/Views/RightDrawerContent.swift` — drop `onConversationAction` param + Settings section's "Новый чат" block.
- `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift` (`SettingsFormBody`) — drop the row that fires `.newChat`.
- `ios/JarvisApp/Sources/JarvisApp/Views/ProfileView.swift` — drop any read of `store.conversations`.
- `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift` — drop `userInfo["conversationId"]` parsing in APNs handler.
- `ios/JarvisApp/project.yml` — regenerate project after file delete.

**Deleted:**
- `ios/JarvisApp/Sources/JarvisApp/Models/Conversation.swift`
- `ios/JarvisApp/Sources/JarvisApp/Models/ConversationAction.swift`
- `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStore.swift`
- `ios/JarvisApp/Sources/JarvisApp/Services/MigrationV2.swift`
- `ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift`

**Tests:**
- `ios/JarvisApp/Sources/JarvisAppTests/SchemaV3MigrationTests.swift` — new
- `ios/JarvisApp/Sources/JarvisAppTests/MessageTimelineTests.swift` — new
- Drop any existing tests for `ConversationStore`, `MigrationV2`, conversation listing.

---

## Task 1: Schema v3 migration — drop conversations table, decouple messages

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/SchemaV3MigrationTests.swift`

- [ ] **Step 1: Write failing migration test**

Create `ios/JarvisApp/Sources/JarvisAppTests/SchemaV3MigrationTests.swift`:

```swift
import XCTest
import GRDB
@testable import JarvisApp

final class SchemaV3MigrationTests: XCTestCase {
    func test_v3_drops_conversations_and_kv_and_recreates_messages_without_conv_id() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)

        try dbq.read { db in
            // conversations + kv should be gone
            let conv = try Bool.fetchOne(db, sql:
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='conversations')")!
            XCTAssertFalse(conv, "conversations table should be dropped")
            let kv = try Bool.fetchOne(db, sql:
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='kv')")!
            XCTAssertFalse(kv, "kv table should be dropped")

            // messages must exist without conversation_id
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(messages)")
                .map { $0["name"] as String }
            XCTAssertTrue(cols.contains("id"))
            XCTAssertTrue(cols.contains("dir"))
            XCTAssertTrue(cols.contains("ts"))
            XCTAssertFalse(cols.contains("conversation_id"), "messages must not have conversation_id")

            // supporting tables present
            for t in ["attachments", "inbound_dedup", "cursors"] {
                let exists = try Bool.fetchOne(db, sql:
                    "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)",
                    arguments: [t])!
                XCTAssertTrue(exists, "\(t) table missing")
            }
        }
    }

    func test_v3_idx_msg_ts_exists() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        try dbq.read { db in
            let idx = try Bool.fetchOne(db, sql:
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_msg_ts')")!
            XCTAssertTrue(idx)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ios/JarvisApp && xcodegen generate
xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:JarvisAppTests/SchemaV3MigrationTests
```
Expected: FAIL — conversations table still exists (current schema is v2).

- [ ] **Step 3: Add `v3-single-chat` migration**

Edit `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift`. After the existing `m.registerMigration("v2-conversation-meta")` block and before `try m.migrate(writer)`, add:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:JarvisAppTests/SchemaV3MigrationTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift \
        ios/JarvisApp/Sources/JarvisAppTests/SchemaV3MigrationTests.swift
git commit -m "feat(jarvis-ios): v3-single-chat migration drops conversations table"
```

---

## Task 2: Trim `ConversationStoreV2` API — remove conversation_id everywhere

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift`

After this task the file *still compiles in isolation* but callers (transport, shim) will break — they get fixed in later tasks.

- [ ] **Step 1: Drop the `conversationId` field from `StoredMessage`**

Edit `ConversationStoreV2.swift`. Replace the `StoredMessage` struct (lines 27-40) with:

```swift
struct StoredMessage: Equatable {
    var id: String
    var dir: MessageDir
    var seq: Int?
    var text: String
    var attachmentsJSON: String?
    var contextJSON: String?
    var status: MessageStatus
    var failureReason: String?
    var ts: Int
    var serverTS: Int?
    var createdAt: Int
}
```

- [ ] **Step 2: Drop the `ensureConversation` helper and conversation-tracking SQL**

In the same file, delete the `ensureConversation(_:id:)` method (lines 46-53). Delete the entire "Conversations API" section (`createConversation`, `conversationSummarySQL`, `mapSummary`, `listConversations`, `archiveConversation`, `deleteConversation`, `renameConversation`, `togglePinned`, `touchLastMessageAt`, `observeConversations`). Delete the "Active conversation persistence" section (`kActiveConversation`, `getKV`, `setKV`, `setActiveConversationId`, `activeConversationId`, `observeActiveConversationId`).

- [ ] **Step 3: Rewrite `insertOutboundUserMessage` without `conversationId`**

Replace the method body (lines 55-84):

```swift
func insertOutboundUserMessage(
    id: String,
    text: String,
    attachments: [V2.Attachment],
    context: V2.InlineContext?
) throws {
    try writer.write { db in
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let encoder = JSONEncoder()
        let attachmentsJSON: String?
        if attachments.isEmpty {
            attachmentsJSON = nil
        } else {
            attachmentsJSON = String(data: try encoder.encode(attachments), encoding: .utf8)
        }
        let contextJSON: String?
        if let c = context {
            contextJSON = String(data: try encoder.encode(c), encoding: .utf8)
        } else {
            contextJSON = nil
        }
        try db.execute(sql: """
            INSERT INTO messages
              (id, dir, seq, text, attachments_json, context_json, status, ts, created_at)
            VALUES (?, 'out', NULL, ?, ?, ?, 'queued', ?, ?)
        """, arguments: [id, text, attachmentsJSON, contextJSON, now, now])
    }
}
```

- [ ] **Step 4: Update `queuedOutbound`, `fetchById`, `insertInbound`, history-import helpers**

Replace `queuedOutbound` (lines 86-110):

```swift
func queuedOutbound(limit: Int = 10) throws -> [StoredMessage] {
    try writer.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM messages
            WHERE dir='out' AND status='queued'
            ORDER BY ts ASC LIMIT ?
        """, arguments: [limit])
        return rows.map { row in
            StoredMessage(
                id: row["id"],
                dir: MessageDir(rawValue: row["dir"]) ?? .out,
                seq: row["seq"],
                text: row["text"],
                attachmentsJSON: row["attachments_json"],
                contextJSON: row["context_json"],
                status: MessageStatus(rawValue: row["status"]) ?? .queued,
                failureReason: row["failure_reason"],
                ts: row["ts"],
                serverTS: row["server_ts"],
                createdAt: row["created_at"]
            )
        }
    }
}
```

Replace `insertInbound` (lines 191-209):

```swift
func insertInbound(envelope: V2.Envelope, message: V2.Message) throws {
    try writer.write { db in
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let encoder = JSONEncoder()
        let attachmentsJSON: String?
        if let atts = message.attachments, !atts.isEmpty {
            attachmentsJSON = String(data: try encoder.encode(atts), encoding: .utf8)
        } else {
            attachmentsJSON = nil
        }
        try db.execute(sql: """
            INSERT INTO messages
              (id, dir, seq, text, attachments_json, status, ts, created_at)
            VALUES (?, 'in', ?, ?, ?, 'new', ?, ?)
        """, arguments: [envelope.id, envelope.seq, message.text, attachmentsJSON, now, now])
    }
}
```

Replace `fetchById` (lines 473-494):

```swift
func fetchById(_ id: String) throws -> StoredMessage? {
    try writer.read { db in
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id=?", arguments: [id]) else {
            return nil
        }
        return StoredMessage(
            id: row["id"],
            dir: MessageDir(rawValue: row["dir"]) ?? .out,
            seq: row["seq"],
            text: row["text"],
            attachmentsJSON: row["attachments_json"],
            contextJSON: row["context_json"],
            status: MessageStatus(rawValue: row["status"]) ?? .queued,
            failureReason: row["failure_reason"],
            ts: row["ts"],
            serverTS: row["server_ts"],
            createdAt: row["created_at"]
        )
    }
}
```

Delete `insertOutboundHistoryRow` and `insertInboundHistoryRow` entirely — they exist only for `MigrationV2`, which is being removed in Task 8.

- [ ] **Step 5: Add `observeMessages` + `prune`**

Append to the class:

```swift
// MARK: - Single-timeline observation + retention

/// Live view of the last `limit` messages, ordered ascending by `ts`.
/// Drives the chat list UI via the `MessageTimeline` wrapper.
func observeMessages(limit: Int = 500)
    -> ValueObservation<ValueReducers.Fetch<[StoredMessage]>>
{
    ValueObservation.tracking { db -> [StoredMessage] in
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM messages
            ORDER BY ts DESC
            LIMIT ?
        """, arguments: [limit])
        return rows.reversed().map { row in
            StoredMessage(
                id: row["id"],
                dir: MessageDir(rawValue: row["dir"]) ?? .out,
                seq: row["seq"],
                text: row["text"],
                attachmentsJSON: row["attachments_json"],
                contextJSON: row["context_json"],
                status: MessageStatus(rawValue: row["status"]) ?? .queued,
                failureReason: row["failure_reason"],
                ts: row["ts"],
                serverTS: row["server_ts"],
                createdAt: row["created_at"]
            )
        }
    }
}

/// Hard-cap retention. Deletes messages beyond `keep` newest, and any
/// orphaned attachments rows. Called by `MessageTimeline` after each insert.
func prune(keep: Int = 500) throws {
    try writer.write { db in
        try db.execute(sql: """
            DELETE FROM messages
            WHERE id NOT IN (
              SELECT id FROM messages ORDER BY ts DESC LIMIT ?
            )
        """, arguments: [keep])
        try db.execute(sql: """
            DELETE FROM attachments
            WHERE message_id NOT IN (SELECT id FROM messages)
        """)
    }
}
```

- [ ] **Step 6: Verify file compiles standalone**

```bash
cd ios/JarvisApp && xcodebuild -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -40
```
Expected: build FAILS but only on call-sites in `WebSocketClientV2`, `TransportV2`, `ConversationStore`, `MigrationV2`. Those are handled in subsequent tasks. Do NOT commit yet — bundle this with Task 3.

---

## Task 3: Wire `ConversationStoreV2` trim into transport + WS client

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift`

- [ ] **Step 1: Fix `TransportV2.swift` outbound envelope construction**

In `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` line 271, the envelope reads `row.conversationId`. Replace the surrounding `V2.Message(...)` call with:

```swift
payload: .message(V2.Message(thread_id: "ios:default", text: row.text,
```

(Leave the rest of that line as-is.)

- [ ] **Step 2: Fix `WebSocketClientV2.swift` — drop conversationId state**

Edit `WebSocketClientV2.swift`. Delete the `var conversationId: UUID? { ... }` property (line ~75 and its observed-state plumbing — find by `grep -n conversationId`). Where it was read, hardcode the thread.

Delete the entire `sendNewConversation(id:)` method (line ~231 area).

In `sendMessage(...)` (line ~277 region), replace:
```swift
let convoString = (conversationId ?? UUID()).uuidString
...
try stack.store.insertOutboundUserMessage(
    conversationId: convoString,
    ...
)
```
with:
```swift
try stack.store.insertOutboundUserMessage(
    id: id,
    text: text,
    attachments: attachments,
    context: contextSnapshot
)
```
(Adjust arg names to whatever the local vars are called — read the existing code.)

In `sendFeedback`, `sendMessageDelivered`, `sendMessageRead` (lines ~295, 316, 323): drop the `conversationId: UUID?` parameter. Where the body uses it to build an envelope, hardcode `thread_id: "ios:default"`.

Delete `reloadActiveConversation()` (line ~407). The legacy callers (AppCoordinator) are removed in Task 5; the v3 timeline is observed via `MessageTimeline`, not reloaded.

Delete the second `WHERE conversation_id=?` query (line ~589) — it's a duplicate of `reloadActiveConversation` content; verify by reading the surrounding method, then remove the dead method entirely.

- [ ] **Step 3: Build to verify transport + ws compile**

```bash
cd ios/JarvisApp && xcodebuild -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -E "error:" | head -30
```
Expected: only errors in `AppCoordinator.swift`, `ConversationStore.swift`, `MigrationV2.swift` (handled next). No errors in `TransportV2` / `WebSocketClientV2`.

- [ ] **Step 4: Commit Tasks 2+3 together**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift
git commit -m "refactor(jarvis-ios): drop conversation_id from store + transport, pin thread_id=ios:default"
```

(The build is intentionally still broken here. Task 4-6 finish the migration.)

---

## Task 4: New `MessageTimeline` observable + tests

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Storage/MessageTimeline.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/MessageTimelineTests.swift`

- [ ] **Step 1: Write failing tests**

Create `ios/JarvisApp/Sources/JarvisAppTests/MessageTimelineTests.swift`:

```swift
import XCTest
import GRDB
@testable import JarvisApp

@MainActor
final class MessageTimelineTests: XCTestCase {
    private func makeStore() throws -> (DatabaseQueue, ConversationStoreV2) {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return (dbq, ConversationStoreV2(writer: dbq))
    }

    func test_outbound_insert_then_markSent_visible() async throws {
        let (dbq, store) = try makeStore()
        let tl = MessageTimeline(store: store, dbq: dbq)
        try await tl.start()

        let msg = try tl.insertOutbound(
            text: "hello",
            attachments: [],
            context: nil
        )
        // Settle observation
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tl.messages.count, 1)
        XCTAssertEqual(tl.messages.first?.text, "hello")

        try store.markSent(id: msg.id, serverTS: 12345)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tl.messages.first?.status, .sent)
    }

    func test_inbound_dedup_keeps_one() async throws {
        let (dbq, store) = try makeStore()
        let tl = MessageTimeline(store: store, dbq: dbq)
        try await tl.start()

        let env = V2.Envelope(id: "abc", seq: 1, ts: "2026-06-04T00:00:00Z", type: .message,
                              payload: nil)
        let m = V2.Message(thread_id: "ios:default", text: "hi", attachments: nil)

        try tl.insertInboundIfNew(envelope: env, message: m)
        try tl.insertInboundIfNew(envelope: env, message: m)   // dedup

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tl.messages.filter { $0.text == "hi" }.count, 1)
    }

    func test_prune_caps_to_limit() async throws {
        let (dbq, store) = try makeStore()
        let tl = MessageTimeline(store: store, dbq: dbq, retention: 3)
        try await tl.start()

        for i in 0..<5 {
            _ = try tl.insertOutbound(text: "m\(i)", attachments: [], context: nil)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tl.messages.count, 3)
        XCTAssertEqual(tl.messages.map { $0.text }, ["m2", "m3", "m4"])
    }
}
```

- [ ] **Step 2: Run, confirm fail**

```bash
cd ios/JarvisApp && xcodegen generate
xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:JarvisAppTests/MessageTimelineTests 2>&1 | tail -20
```
Expected: FAIL — `MessageTimeline` symbol unknown.

- [ ] **Step 3: Implement `MessageTimeline.swift`**

Create `ios/JarvisApp/Sources/JarvisApp/Storage/MessageTimeline.swift`:

```swift
import Foundation
import GRDB

/// `@Observable` UI-facing wrapper around `ConversationStoreV2`. Single source
/// of truth for the chat timeline. Replaces the legacy `ConversationStore`
/// drawer shim now that there is no concept of multiple conversations.
@MainActor
@Observable
final class MessageTimeline {
    private(set) var messages: [StoredMessage] = []

    private let store: ConversationStoreV2
    private let dbq: DatabaseQueue
    private let retention: Int
    private var observationCancellable: AnyDatabaseCancellable?

    init(store: ConversationStoreV2, dbq: DatabaseQueue, retention: Int = 500) {
        self.store = store
        self.dbq = dbq
        self.retention = retention
    }

    /// Begin observing the GRDB-backed message timeline. Idempotent.
    func start() async throws {
        guard observationCancellable == nil else { return }
        let observation = store.observeMessages(limit: retention)
        // Seed synchronously so views render on first frame.
        self.messages = try await dbq.read { db in
            try observation.fetch(db)
        }
        observationCancellable = observation.start(
            in: dbq,
            scheduling: .async(onQueue: .main),
            onError: { Log.warn(.cache, "MessageTimeline observation error: \($0)") },
            onChange: { [weak self] rows in
                self?.messages = rows
            }
        )
    }

    @discardableResult
    func insertOutbound(text: String,
                        attachments: [V2.Attachment],
                        context: V2.InlineContext?) throws -> StoredMessage {
        let id = UUID().uuidString
        try store.insertOutboundUserMessage(
            id: id, text: text, attachments: attachments, context: context
        )
        try store.prune(keep: retention)
        // Synthesize the row for callers that need it immediately.
        return StoredMessage(
            id: id, dir: .out, seq: nil, text: text,
            attachmentsJSON: nil, contextJSON: nil,
            status: .queued, failureReason: nil,
            ts: Int(Date().timeIntervalSince1970 * 1000),
            serverTS: nil,
            createdAt: Int(Date().timeIntervalSince1970 * 1000)
        )
    }

    func insertInboundIfNew(envelope: V2.Envelope, message: V2.Message) throws {
        if try store.dedupSeen(id: envelope.id) { return }
        try store.recordDedup(id: envelope.id, seq: envelope.seq ?? 0)
        try store.insertInbound(envelope: envelope, message: message)
        try store.prune(keep: retention)
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

```bash
cd ios/JarvisApp && xcodegen generate
xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:JarvisAppTests/MessageTimelineTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/MessageTimeline.swift \
        ios/JarvisApp/Sources/JarvisAppTests/MessageTimelineTests.swift
git commit -m "feat(jarvis-ios): MessageTimeline observable replaces ConversationStore shim"
```

---

## Task 5: Delete obsolete files (Conversation*, MigrationV2, ConversationListView, ConversationStore)

**Files (delete):**
- `ios/JarvisApp/Sources/JarvisApp/Models/Conversation.swift`
- `ios/JarvisApp/Sources/JarvisApp/Models/ConversationAction.swift`
- `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStore.swift`
- `ios/JarvisApp/Sources/JarvisApp/Services/MigrationV2.swift`
- `ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift`

- [ ] **Step 1: Remove files**

```bash
git rm ios/JarvisApp/Sources/JarvisApp/Models/Conversation.swift \
       ios/JarvisApp/Sources/JarvisApp/Models/ConversationAction.swift \
       ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStore.swift \
       ios/JarvisApp/Sources/JarvisApp/Services/MigrationV2.swift \
       ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift
```

- [ ] **Step 2: Regenerate Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 3: Verify build fails on expected sites only**

```bash
xcodebuild -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -E "error:" | head -30
```
Expected errors point only to: `AppCoordinator.swift`, `AppV2Bootstrap.swift`, `ChatView.swift`, `OrbHomeView.swift`, `RightDrawerContent.swift`, `SettingsView.swift`, `ProfileView.swift`, `JarvisApp.swift`. Those are handled in Tasks 6-8.

- [ ] **Step 4: Do not commit yet** — bundle with Task 6.

---

## Task 6: Update `AppCoordinator` + `AppV2Bootstrap`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppV2Bootstrap.swift`

- [ ] **Step 1: `AppV2Bootstrap.swift` — return `MessageTimeline`**

Edit `AppV2Bootstrap.swift`. Replace `buildStorage()` (lines 25-39):

```swift
static func buildStorage() throws -> (dbq: DatabaseQueue, store: ConversationStoreV2, timeline: MessageTimeline) {
    let docs = try FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    let dbURL = docs.appendingPathComponent("jarvis-v2.sqlite")
    let dbq = try DatabaseQueue(path: dbURL.path)
    try Schema.migrate(dbq)
    let store = ConversationStoreV2(writer: dbq)
    let timeline = MessageTimeline(store: store, dbq: dbq)
    return (dbq, store, timeline)
}
```

The `AppV2Stack` struct (lines 7-12) does *not* need a timeline field — callers grab it through the build tuple. Update the two `build(...)` variants below to drop the legacy `try MigrationV2.runIfNeeded(...)` line, and adapt the `storage:` tuple type in the second variant to the new 3-tuple shape:

```swift
static func build(
    serverURL: URL,
    token: String,
    storage: (dbq: DatabaseQueue, store: ConversationStoreV2, timeline: MessageTimeline),
    location: LocationManager? = nil,
    health: HealthManager? = nil,
    calendar: CalendarManager? = nil
) -> AppV2Stack {
    let socket = URLSessionWebSocket(url: serverURL)
    let coordinator = AppContextCoordinator(location: location, health: health, calendar: calendar)
    let transport = TransportV2(
        store: storage.store,
        socket: socket,
        token: token,
        contextCoordinator: coordinator
    )
    return AppV2Stack(store: storage.store, transport: transport, coordinator: coordinator, dbq: storage.dbq)
}
```

The first `build(serverURL:token:location:health:calendar:)` variant calls `buildStorage()`; update its tuple destructure:

```swift
let (dbq, store, _) = try buildStorage()
```

(Drop the unused timeline; callers that want it use `buildStorage()` directly.)

- [ ] **Step 2: `AppCoordinator.swift` — swap store type, drop handleAction/openConversation**

Edit `AppCoordinator.swift`:

- Replace `private(set) var store: ConversationStore!` (line 17) with:
  ```swift
  private(set) var timeline: MessageTimeline!
  ```
- In `init(...)`, replace the storage-init block (lines 58-67):
  ```swift
  let storage: (dbq: GRDB.DatabaseQueue, store: ConversationStoreV2, timeline: MessageTimeline)?
  do {
      storage = try AppV2Bootstrap.buildStorage()
  } catch {
      Log.warn(.ws, "AppCoordinator buildStorage failed: \(error)")
      storage = nil
  }
  if let storage {
      self.timeline = storage.timeline
      Task { @MainActor in try? await storage.timeline.start() }
  }
  self.ws = WebSocketClientV2(
      location: location, health: health, calendar: calendar,
      storage: storage.map { ($0.dbq, $0.store) }
  )
  ```
  (Adjust the `WebSocketClientV2` init signature in Task 3 if it kept the old 2-tuple shape — it should expect `(dbq, store)`.)

- Delete the `AppDelegate.onOpenConversation = { ... }` block (lines 103-105). Push deep-links no longer route to conversations.
- Delete `handleAction(_:)` entirely (lines 182-208).
- Delete `openConversation(id:)` entirely (lines 210-216).
- In `sendMessage(...)` (lines 136-167), delete the block:
  ```swift
  if let store, let cid = store.activeConversationId {
      store.recordUserSend(conversationId: cid, text: text)
  }
  ```
- In `sendFeedback(...)` line 175, replace with:
  ```swift
  ws.sendFeedback(messageId: messageId, value: value, messageText: messageText)
  ```
  (Drops the `conversationId:` arg consistent with Task 3.)
- In `wireUp()` (lines 220-278): delete the `ws.conversationId = store?.activeConversationId` line, delete the `ws.reloadActiveConversation()` call, and delete the `if let store = self.store, let cid = self.ws.conversationId { store.recordIncoming(...) }` block.
- Replace any other `self.store` reference with `self.timeline`.

- [ ] **Step 3: Build, check remaining errors are only in Views/JarvisApp.swift**

```bash
cd ios/JarvisApp && xcodegen generate
xcodebuild -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -E "error:" | head -30
```
Expected: errors only in `ChatView.swift`, `OrbHomeView.swift`, `RightDrawerContent.swift`, `SettingsView.swift`, `ProfileView.swift`, `JarvisApp.swift`.

- [ ] **Step 4: Do not commit yet** — bundle with Task 7.

---

## Task 7: Strip multi-chat UI from views

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/RightDrawerContent.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ProfileView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift`

- [ ] **Step 1: `ChatView.swift`**

In `ChatView.swift`:
- Delete the `private var store: ConversationStore { coordinator.store }` accessor at line 38; replace with `private var timeline: MessageTimeline { coordinator.timeline }`.
- Delete the leading drawer overlay — find `DrawerContent(` around line 265 and remove the whole drawer view tree it sits inside, plus any swipe gesture that opens it.
- In the `RightDrawerContent(...)` call at line 294, drop the `onConversationAction:` argument entirely. Caller becomes:
  ```swift
  RightDrawerContent(
      isConnected: coordinator.connectionPhase == .connected,
      onReconnect: { coordinator.connect() }
  )
  ```
  (Drop `store:` arg too — see RightDrawerContent edit below.)
- Replace all reads of `store.activeConversation?.title` or similar with the static string `"Jarvis"`.
- Replace any `ws.messages` or `store.messages` read with `timeline.messages`. Map `StoredMessage` to the existing `ChatMessage` view-model — verify the conversion exists or inline it (see ChatView's existing message rendering).

- [ ] **Step 2: `OrbHomeView.swift`**

- Delete the leading-drawer overlay block at line 162 (`DrawerContent(`). Remove its presenting state + gesture.
- Delete or simplify the `RightDrawerContent(...)` call at line 182: drop `store:` and `onConversationAction:` args.
- If the orb tap path triggers `.newChat`, replace with no-op (orb opens chat that already exists).

- [ ] **Step 3: `RightDrawerContent.swift`**

- Drop the `store: ConversationStore` property entirely.
- Drop the `var onConversationAction: ((ConversationAction) -> Void)? = nil` property.
- Update the `ProfileFormBody(store: store, ...)` call: pass `nil` or rewrite `ProfileFormBody` to no longer take the store (see Task 7.5).
- Update the `SettingsFormBody(store: store, onConversationAction: onConversationAction)` call: drop both args; see Task 7.4.

- [ ] **Step 4: `SettingsView.swift` / `SettingsFormBody`**

- Drop the `store:` and `onConversationAction:` parameters from `SettingsFormBody`.
- Delete the UI row that fires `.newChat` (look for `Button { onConversationAction?(.newChat) }` or similar).
- Wire callers: in any place `SettingsFormBody(...)` is constructed, remove those args.

- [ ] **Step 5: `ProfileView.swift`**

- Drop the `store: ConversationStore` parameter from `ProfileFormBody` (and `ProfileView` if present).
- Replace any read of `store.conversations.count` or `store.activeConversation` with hard-coded values or remove the row entirely (e.g. if it showed "N диалогов" — delete the row).
- Wire callers: drop the `store:` arg everywhere `ProfileFormBody(...)` / `ProfileView(...)` is used.

- [ ] **Step 6: `JarvisApp.swift` — APNs**

In `JarvisApp.swift` around line 50, delete the `if let cid = response.notification.request.content.userInfo["conversationId"] as? String { ... }` block in `userNotificationCenter(_:didReceive:withCompletionHandler:)`. Also delete the `AppDelegate.onOpenConversation` static var declaration (search for it). The push handler just resolves the notification — opening the app is enough.

- [ ] **Step 7: Build clean**

```bash
cd ios/JarvisApp && xcodegen generate
xcodebuild -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Run full test suite**

```bash
xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -30
```
Expected: all tests PASS. If any pre-existing `ConversationStore*` / `MigrationV2*` tests fail with "unknown symbol", delete them in this commit.

- [ ] **Step 9: Commit Tasks 5-7 together**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(jarvis-ios): drop multi-conversation UI and drawer

Delete Conversation, ConversationAction, ConversationStore, MigrationV2,
ConversationListView. Strip the leading drawer from ChatView and
OrbHomeView; trim RightDrawerContent / SettingsFormBody / ProfileFormBody
to drop the store + onConversationAction wiring. APNs handler no longer
parses conversationId. AppCoordinator owns a MessageTimeline observable
instead of the legacy ConversationStore shim.
EOF
)"
```

---

## Task 8: First-launch v3 toast (one-shot informational)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

- [ ] **Step 1: Add an `@AppStorage`-gated toast**

In `ChatView.swift`, add at the top of the view struct:

```swift
@AppStorage("v3MigrationShown") private var v3MigrationShown = false
@State private var showingV3Toast = false
```

In the view body, before the toolbar `.body` end, attach:

```swift
.onAppear {
    if !v3MigrationShown {
        showingV3Toast = true
        v3MigrationShown = true
    }
}
.alert("История чата обновлена",
       isPresented: $showingV3Toast) {
    Button("ОК", role: .cancel) {}
} message: {
    Text("Jarvis теперь один непрерывный чат. Локальная история диалогов до обновления была удалена. Контекст агента сохранён на сервере.")
}
```

- [ ] **Step 2: Build, smoke**

```bash
cd ios/JarvisApp && xcodebuild -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "feat(jarvis-ios): one-shot v3 migration toast"
```

---

## Task 9: Manual smoke + simulator verification

- [ ] **Step 1: Launch in simulator**

```bash
cd ios/JarvisApp && xcodebuild -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
xcrun simctl boot 'iPhone 15' || true
xcrun simctl install booted .build/Build/Products/Debug-iphonesimulator/JarvisApp.app
xcrun simctl launch booted com.vasechko.jarvis
```

- [ ] **Step 2: Verify against checklist (manual, simulator)**

- Splash → chat appears.
- No left drawer / gesture / "Диалоги" anywhere in UI.
- Right drawer opens; Profile + Context toggles + Settings render; no "Новый чат" row.
- Send a test message — appears in chat with `sending`/`sent` state.
- Kill app, relaunch — prior messages still visible (GRDB persisted).
- v3 toast appears once on first launch; doesn't reappear.

If any step fails, fix and amend the relevant commit before proceeding.

- [ ] **Step 3: No commit needed** if smoke passes.

---

## Task 10: Post-deploy ops — stale server sessions

**Files:** (documentation only — operations runbook)

- [ ] **Step 1: Add a runbook note**

Edit `docs/superpowers/specs/2026-06-04-jarvis-single-chat-design.md` (post-deploy ops section already exists). No code change needed — verify the section reads correctly. If the spec needs sharpening, edit inline.

- [ ] **Step 2: After client deploy to TestFlight / device, on VDS**

```bash
ssh root@148.253.211.164
sudo -u nanoclaw bash -c "cd ~/nanoclaw && pnpm exec tsx scripts/q.ts data/v2.db \
  \"SELECT id, thread_id FROM sessions WHERE messaging_group_id IN \
    (SELECT id FROM messaging_groups WHERE channel='ios-app') AND thread_id != 'ios:default'\""
```

For each stale row, manually remove `data/v2-sessions/<agent-group>/<session>/` and delete the row. This is one-off; do not script it.

- [ ] **Step 3: Verify new session created with `ios:default`**

After the iOS client sends its first v3 message:

```bash
sudo -u nanoclaw bash -c "cd ~/nanoclaw && pnpm exec tsx scripts/q.ts data/v2.db \
  \"SELECT id, thread_id, last_active_at FROM sessions WHERE thread_id='ios:default'\""
```

Expected: one row, recent `last_active_at`.

---

## Final state

After all tasks:

- `data/v2.db` on server: one session row keyed on `thread_id='ios:default'` per agent_group (Jarvis).
- iOS app: single-timeline chat, no drawer, no list, no pin/archive/new-chat affordances. GRDB at `Documents/jarvis-v2.sqlite` has `messages`, `attachments`, `inbound_dedup`, `cursors` only.
- Server protocol (`src/channels/ios-app/v2/*`): unchanged.
- Watch companion (`WatchConnectivityBridge` push) still works — it doesn't reference conversations.
