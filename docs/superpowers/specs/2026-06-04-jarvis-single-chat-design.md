# Jarvis Single-Chat — Design

**Date:** 2026-06-04
**Scope:** iOS app (`ios/JarvisApp/`) — remove multi-conversation infrastructure. Server-side iOS-app channel adapter is unchanged.

## Goal

Jarvis is a real-time assistant, not a chat archive. Strip the multi-conversation UI and storage from the iOS app so the user only ever sees one continuous message stream. The server keeps its thread-aware contract; the client always pins the same `thread_id`.

## Non-goals

- No changes to `src/channels/ios-app/v2/*` (envelope shape, dispatch, queueing).
- No changes to the nanoclaw session model (`sessions` table still keys on `thread_id`).
- No migration of historical messages from the old client schema to the new one. Old local data is dropped.
- No server-side cleanup of pre-existing iOS sessions in `data/v2.db` — handled manually post-deploy.

## Architecture overview

- **Server session.** The iOS channel adapter continues to receive `thread_id` in inbound envelopes. The client always sends `thread_id = "ios:default"`. On the server side this resolves to one persistent nanoclaw session per (messaging_group, agent_group); the container lives until normal sweep rules retire it.
- **Client state.** A single `MessageStore` replaces both `ConversationStore` and `ConversationStoreV2`. Backed by GRDB with one `messages` table (no `conversation_id`). UI binds to `store.messages` directly.
- **UI shape.** No left drawer, no conversation list, no pin/archive/delete, no "new chat" affordance anywhere. Chat title is static ("Jarvis"). The right drawer keeps Profile, Context (proactive toggles), and Settings, minus the "Новый чат / диалоги" block.

## Components

### `Storage/Schema.swift` — new migration `v3-single-chat`

Drops `conversations`, `messages`, `attachments`, `inbound_dedup`, `kv`. Recreates `messages` without `conversation_id`, plus fresh `attachments`, `inbound_dedup`, `cursors`. Indices: `idx_msg_ts (ts)`, `idx_msg_status (status)`.

```sql
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

CREATE TABLE cursors (k TEXT PRIMARY KEY, v INTEGER NOT NULL);
```

Migration is destructive — the `v3-single-chat` migration runs once per install via `DatabaseMigrator`. Pre-`v3` users see an empty timeline on first launch after the update.

### `Storage/MessageStore.swift` — new

Replaces `ConversationStore` and `ConversationStoreV2`.

```swift
@Observable
final class MessageStore {
    private(set) var messages: [Message] = []   // ts ASC, capped at 500
    private let dbq: DatabaseQueue
    private var observationCancellable: AnyDatabaseCancellable?

    init(dbq: DatabaseQueue) { ... }

    func insertOutbound(text: String,
                        attachmentsJSON: String?,
                        contextJSON: String?) -> Message
    func markSent(id: String, serverTs: Int64)
    func markFailed(id: String, reason: String)

    func insertInbound(id: String, seq: Int64, text: String, serverTs: Int64)
    func insertInboundImage(id: String, seq: Int64, attachmentsJSON: String, serverTs: Int64)

    private func prune()   // keep last 500 ordered by ts DESC; cascade-delete attachments + JPGs
}
```

- `ValueObservation` on `SELECT * FROM messages ORDER BY ts ASC LIMIT 500` drives `messages`.
- Dedup on inbound: `INSERT OR IGNORE INTO inbound_dedup`. If conflict → drop.
- `prune()` runs after every inbound/outbound insert. Orphaned JPGs in `Documents/MessageCache/` are deleted by id-match.

### `Services/AppCoordinator.swift`

- Replace `store: ConversationStore` with `store: MessageStore`.
- Remove `handleAction(_:)` entirely (its only callers — drawers — are gone).
- WS callbacks (`onMessage`, `onImage`, `onSendStatus`) call `store.insertInbound` / `store.markSent` / `store.markFailed` directly.

### `Services/AppV2Bootstrap.swift`

- `buildStorage()` returns `(dbq, MessageStore)` instead of `(dbq, ConversationStoreV2)`.

### `Services/WebSocketClient.swift`

- `send(message:)` hardcodes `thread_id: "ios:default"` in the envelope payload. No `conversationId` arg anywhere.
- Remove `sendNewConversation()` if present — the `new_conversation` envelope is never emitted from iOS.
- APNs token handler unchanged.

### `JarvisApp.swift`

- Remove the `if let cid = response.notification.request.content.userInfo["conversationId"] as? String { ... }` block at line ~50. Push opens the app; no thread switching.

### Views

- `ChatView.swift`: drop `leadingDrawer` overlay, drop the gesture wiring opening it, drop `onAction:` callback handling for `ConversationAction`. Title bar shows static `"Jarvis"`. Toolbar: emoji picker + right-drawer button.
- `OrbHomeView.swift`: drop `DrawerContent` overlay (left drawer). Drop `newChat` from `onAction` paths. Orb tap → existing chat (one session).
- `RightDrawerContent.swift`: drop the `onConversationAction:` parameter. Drop the "Новый чат / диалоги" call sites inside `SettingsFormBody`.
- `SettingsView.swift` / `SettingsFormBody`: drop the row that triggered `.newChat`.
- `ProfileView.swift`: if it reads `store.conversations` for anything (count of chats, etc.), drop that read. Profile shows user-level state, not conversation-level.

### Files to delete

```
ios/JarvisApp/Sources/JarvisApp/Models/Conversation.swift
ios/JarvisApp/Sources/JarvisApp/Models/ConversationAction.swift
ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStore.swift
ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift
ios/JarvisApp/Sources/JarvisApp/Services/MigrationV2.swift
ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift
```

After deletes: `xcodegen generate` from `ios/JarvisApp/` to regenerate the project file. Also drop references from `project.yml` if any are explicit.

## Data flow

**Outbound (user sends):**

1. `InputBar` → `AppCoordinator.send(text:)`
2. `MessageStore.insertOutbound(text:, attachmentsJSON:, contextJSON:)` → row inserted (`status='sending'`), ValueObservation fires, UI updates.
3. `WebSocketClient.send` emits envelope `{ type: 'message', payload: { thread_id: 'ios:default', text, ... } }`.
4. Server ack → `onSendStatus(id, serverTs)` → `store.markSent`.
5. On failure → `store.markFailed(id, reason)`; row stays visible with error state.

**Inbound (agent replies / proactive push):**

1. WS frame arrives → `onMessage(id, seq, text, serverTs)` (or `onImage`).
2. `store.insertInbound` → dedup check → insert → ValueObservation fires.
3. `prune()` trims to 500 most recent.

**Server thread routing:** the channel adapter sees `thread_id="ios:default"`, looks up or creates a `sessions` row for `(messaging_group=ios-app, agent_group=jarvis, thread_id="ios:default")`. From there it's the normal nanoclaw flow.

## Error handling

- **DB migration fails on `v3-single-chat`:** crash on launch (current `Schema.migrate` behavior). Acceptable — destructive migration, no rollback path. User reinstalls if it happens.
- **`v2.db` corruption / missing:** existing bootstrap recreates the DB. With v3 schema everything starts empty.
- **Old WS envelope received from server** (`new_conversation` echoed back, or `conversationId` in an outbound envelope): ignored. iOS client doesn't parse `conversationId` anywhere post-change.
- **Old APNs payload with `conversationId`:** ignored. Push wakes app, opens the one chat.

## One-time post-deploy ops (server)

After the iOS update ships and existing users restart:

```bash
# On VDS, identify stale ios-app sessions
sudo -u nanoclaw bash -c "cd ~/nanoclaw && pnpm exec tsx scripts/q.ts data/v2.db \
  \"SELECT id, thread_id FROM sessions WHERE messaging_group_id IN \
    (SELECT id FROM messaging_groups WHERE channel='ios-app') AND thread_id != 'ios:default'\""

# For each stale id, remove the session row and its data/v2-sessions/<group>/<id>/ dir
```

Not automated — one-off cleanup. New traffic will reuse `ios:default` automatically.

## Testing

- **New:** `MessageStoreTests` — insertOutbound + markSent, insertInbound + dedup, prune at boundary (501 → 500), orphan attachment cleanup.
- **Updated:** `WebSocketClientTests` — outbound envelope always carries `thread_id: "ios:default"`; no `new_conversation` envelope emitted.
- **Deleted:** any `ConversationStoreV2Tests` / `MigrationV2Tests` / `ConversationListViewTests`.
- **Server tests** (`src/channels/ios-app/v2/*.test.ts`): unchanged. Contract is stable.
- **Manual smoke:** boot fresh install on simulator, send message, receive reply, kill app, relaunch — see prior messages restored from DB. APNs push opens app to the same timeline.

## Out of scope / future

- Voice-only mode tweaks (already exists in `OrbVoiceView`).
- Persisting more than 500 messages or longer retention.
- Bringing threads back, ever.

## Risks

- **User loses local history on upgrade.** Acceptable — one-time toast on first v3 launch (`@AppStorage("v3MigrationShown")`) explains. Server-side context (the agent's session memory) is intact since `thread_id="ios:default"` reuses the existing session id only if that id matches; otherwise the agent gets a fresh session. Acceptable consequence.
- **`xcodegen` reference rot.** Easy to miss a stale file reference in `project.yml`. Mitigation: full clean build after regen, fix any "missing file" errors before commit.
