# Delivery Status + Read Receipts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track message delivery states (sending→sent→delivered) on iOS with WhatsApp-style checkmarks, and send read receipts to the server so the agent sees when messages are read.

**Architecture:** Three layers — (1) iOS model adds `DeliveryStatus` enum; (2) WS protocol gains `clientMessageId`/`message_ack` for outgoing delivery and `message_delivered`/`message_read` for incoming receipts; (3) server stores receipts in `data/ios-read-receipts.json` and injects them into the agent context on the next `context_response`.

**Tech Stack:** Swift 5.9 / SwiftUI (iOS), TypeScript / Node.js (server), vitest (server tests), xcodegen + Xcode (iOS build verification)

---

## File Map

| File | Action | What changes |
|------|--------|-------------|
| `src/channels/ios-read-receipts.ts` | Create | `ReadReceiptStore` class — pure logic, no FS deps, fully testable |
| `src/channels/ios-read-receipts.test.ts` | Create | Vitest unit tests for ReadReceiptStore |
| `src/channels/ios-app.ts` | Modify | Import store; handle `message_ack`, `message_delivered`, `message_read`; inject into `context_response`; extend `buildCtx` |
| `ios/JarvisApp/Sources/JarvisApp/Models/Message.swift` | Modify | Add `DeliveryStatus` enum + `var deliveryStatus: DeliveryStatus` to `ChatMessage` |
| `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift` | Modify | `send()` uses `clientMessageId`; handle `message_ack`; `sendMessageDelivered`/`sendMessageRead`; dedup set |
| `ios/JarvisApp/Sources/JarvisApp/Services/MessageCache.swift` | Modify | `CachedMessage` gains `deliveryStatus: String?`; restore on load |
| `ios/JarvisApp/Sources/JarvisApp/Components/MessageBubble.swift` | Modify | Checkmark icons for `.user` role messages |
| `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` | Modify | `.onAppear` on assistant message rows calls read receipt callback |

---

## Task 1: ReadReceiptStore — pure module with tests

**Files:**
- Create: `src/channels/ios-read-receipts.ts`
- Create: `src/channels/ios-read-receipts.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// src/channels/ios-read-receipts.test.ts
import { describe, it, expect, beforeEach } from 'vitest';
import { ReadReceiptStore } from './ios-read-receipts.js';

describe('ReadReceiptStore', () => {
  let store: ReadReceiptStore;
  beforeEach(() => { store = new ReadReceiptStore(); });

  it('records delivered event', () => {
    store.record('ios:abc', 'msg1', 'delivered');
    const pending = store.getPending('ios:abc');
    expect(pending).toHaveLength(1);
    expect(pending[0].messageId).toBe('msg1');
    expect(pending[0].deliveredAt).toBeTruthy();
    expect(pending[0].readAt).toBeUndefined();
    expect(pending[0].injected).toBe(false);
  });

  it('records read event on existing entry', () => {
    store.record('ios:abc', 'msg1', 'delivered');
    store.record('ios:abc', 'msg1', 'read');
    const pending = store.getPending('ios:abc');
    expect(pending[0].readAt).toBeTruthy();
  });

  it('creates entry for read without prior delivered', () => {
    store.record('ios:abc', 'msg1', 'read');
    const pending = store.getPending('ios:abc');
    expect(pending).toHaveLength(1);
    expect(pending[0].readAt).toBeTruthy();
  });

  it('getPending returns only uninjected entries for given pid', () => {
    store.record('ios:abc', 'msg1', 'delivered');
    store.record('ios:xyz', 'msg2', 'delivered');
    expect(store.getPending('ios:abc')).toHaveLength(1);
    expect(store.getPending('ios:xyz')).toHaveLength(1);
  });

  it('markInjected prevents entries from appearing in getPending', () => {
    store.record('ios:abc', 'msg1', 'delivered');
    const pending = store.getPending('ios:abc');
    store.markInjected(pending);
    expect(store.getPending('ios:abc')).toHaveLength(0);
  });

  it('getPending returns at most 20 entries', () => {
    for (let i = 0; i < 25; i++) store.record('ios:abc', `msg${i}`, 'delivered');
    expect(store.getPending('ios:abc')).toHaveLength(20);
  });

  it('hydrate restores state from serialized lines', () => {
    const r = { messageId: 'msg1', pid: 'ios:abc', deliveredAt: '2026-01-01T00:00:00Z', injected: false };
    store.hydrate([JSON.stringify(r)]);
    expect(store.getPending('ios:abc')).toHaveLength(1);
  });

  it('serialize returns a JSON string', () => {
    const line = store.serialize({ messageId: 'msg1', pid: 'ios:abc', deliveredAt: '2026-01-01T00:00:00Z', injected: false });
    expect(() => JSON.parse(line)).not.toThrow();
  });
});
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
pnpm test -- src/channels/ios-read-receipts.test.ts
```

Expected: `Error: Cannot find module './ios-read-receipts.js'`

- [ ] **Step 3: Implement ReadReceiptStore**

```typescript
// src/channels/ios-read-receipts.ts
export interface ReadReceipt {
  messageId: string;
  pid: string;
  deliveredAt: string;  // ISO string
  readAt?: string;
  injected: boolean;
}

export class ReadReceiptStore {
  private entries = new Map<string, ReadReceipt>();

  private key(pid: string, messageId: string): string {
    return `${pid}:${messageId}`;
  }

  record(pid: string, messageId: string, type: 'delivered' | 'read'): void {
    const k = this.key(pid, messageId);
    const now = new Date().toISOString();
    const existing = this.entries.get(k);
    if (type === 'delivered') {
      if (!existing) {
        this.entries.set(k, { messageId, pid, deliveredAt: now, injected: false });
      }
    } else {
      if (existing) {
        existing.readAt = now;
      } else {
        this.entries.set(k, { messageId, pid, deliveredAt: now, readAt: now, injected: false });
      }
    }
  }

  getPending(pid: string): ReadReceipt[] {
    const result: ReadReceipt[] = [];
    for (const r of this.entries.values()) {
      if (r.pid === pid && !r.injected) result.push(r);
    }
    return result.slice(0, 20);
  }

  markInjected(receipts: ReadReceipt[]): void {
    for (const r of receipts) {
      const e = this.entries.get(this.key(r.pid, r.messageId));
      if (e) e.injected = true;
    }
  }

  hydrate(lines: string[]): void {
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const r = JSON.parse(trimmed) as ReadReceipt;
        if (r.messageId && r.pid) {
          this.entries.set(this.key(r.pid, r.messageId), r);
        }
      } catch {}
    }
  }

  serialize(receipt: ReadReceipt): string {
    return JSON.stringify(receipt);
  }

  all(): ReadReceipt[] {
    return Array.from(this.entries.values());
  }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
pnpm test -- src/channels/ios-read-receipts.test.ts
```

Expected: all 8 tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-read-receipts.ts src/channels/ios-read-receipts.test.ts
git commit -m "feat(ios-channel): ReadReceiptStore module with tests"
```

---

## Task 2: ios-app.ts — ack + receipt handlers + persistence

**Files:**
- Modify: `src/channels/ios-app.ts`

- [ ] **Step 1: Add import + store init near the top of ios-app.ts, after existing constants**

Find the block (around line 39–50):
```typescript
const TOKENS_FILE = path.join(process.cwd(), 'data', 'ios-apns-tokens.json');
```

Add after `TOKENS_FILE`:
```typescript
import { ReadReceiptStore } from './ios-read-receipts.js';

const READ_RECEIPTS_FILE = path.join(process.cwd(), 'data', 'ios-read-receipts.json');
const readReceiptStore = new ReadReceiptStore();
```

> Note: the import goes at the top of the file with the other imports (line 1–9 area). The constant goes after `TOKENS_FILE`.

- [ ] **Step 2: Load persisted receipts at startup**

Find `function savePersistedTokens` (around line 106). Add the load call directly after `savePersistedTokens` definition:

```typescript
// Load persisted read receipts
(function loadReadReceipts() {
  try {
    const data = fs.readFileSync(READ_RECEIPTS_FILE, 'utf8');
    const arr = JSON.parse(data) as unknown[];
    if (Array.isArray(arr)) {
      readReceiptStore.hydrate(arr.map((r) => JSON.stringify(r)));
    }
  } catch {}
})();
```

- [ ] **Step 3: Add persist helper function**

After `loadReadReceipts`:
```typescript
function persistReadReceipts(): void {
  try {
    fs.writeFileSync(READ_RECEIPTS_FILE, JSON.stringify(readReceiptStore.all()), 'utf8');
  } catch (e) {
    log(`persistReadReceipts failed: ${e instanceof Error ? e.message : String(e)}`);
  }
}
```

- [ ] **Step 4: Handle message_delivered and message_read in the WS message handler**

Find the block `if (msg.type === 'message' && typeof msg.text === 'string' && pid)` (around line 462). Add before it:

```typescript
if (msg.type === 'message_delivered' && pid && typeof msg.messageId === 'string') {
  readReceiptStore.record(pid, msg.messageId, 'delivered');
  persistReadReceipts();
}

if (msg.type === 'message_read' && pid && typeof msg.messageId === 'string') {
  readReceiptStore.record(pid, msg.messageId, 'read');
  persistReadReceipts();
}
```

- [ ] **Step 5: Send message_ack after onInbound for user messages**

Find the closing of the `if (msg.type === 'message' ...)` block (after `await cfg!.onInbound(...)` around line 479–485). Add immediately after `await cfg!.onInbound(...)`:

```typescript
// Ack the client so it can transition from .sent → .delivered
if (typeof msg.clientMessageId === 'string' && msg.clientMessageId) {
  ws.send(JSON.stringify({ type: 'message_ack', clientMessageId: msg.clientMessageId }));
}
```

- [ ] **Step 6: Build to verify TypeScript compiles**

```bash
pnpm run build
```

Expected: no TypeScript errors

- [ ] **Step 7: Commit**

```bash
git add src/channels/ios-app.ts
git commit -m "feat(ios-channel): message_ack + read receipt storage"
```

---

## Task 3: ios-app.ts — context injection + buildCtx extension

**Files:**
- Modify: `src/channels/ios-app.ts`

- [ ] **Step 1: Inject pending read receipts into context_response**

Find the `context_response` handler (around line 510–530):

```typescript
if (msg.type === 'context_response' && pid) {
  const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
  const ctx = (msg.context as Record<string, unknown> | undefined) ?? {};
  if (typeof ctx.timezone !== 'string' && lastTimezone.has(pid)) ctx.timezone = lastTimezone.get(pid);
```

Add after the timezone line, before `let block`:
```typescript
  const pendingReceipts = readReceiptStore.getPending(pid);
  if (pendingReceipts.length > 0) {
    ctx.readReceipts = pendingReceipts;
    readReceiptStore.markInjected(pendingReceipts);
  }
```

- [ ] **Step 2: Extend buildCtx to format read receipts**

Find `buildCtx` function (around line 692). Find the section before the final `return` that builds the header line:

```typescript
  if (!lines.length && !ctx.status) return '';
```

Change to:
```typescript
  if (!lines.length && !ctx.status && !Array.isArray(ctx.readReceipts)) return '';
```

Then find the block that builds `statusSuffix` and `return`. Add between `lines` construction and the final `return`:

```typescript
  if (Array.isArray(ctx.readReceipts) && ctx.readReceipts.length > 0) {
    const tz = (ctx.timezone as string | undefined) ?? 'Europe/Moscow';
    const fmtTime = (iso: string) =>
      new Date(iso).toLocaleTimeString('ru-RU', { timeZone: tz, hour: '2-digit', minute: '2-digit' });
    lines.push('[read receipts]');
    for (const r of ctx.readReceipts as Array<{ messageId: string; deliveredAt: string; readAt?: string }>) {
      const short = r.messageId.slice(0, 8);
      const d = `delivered ${fmtTime(r.deliveredAt)}`;
      const rd = r.readAt ? `, read ${fmtTime(r.readAt)}` : '';
      lines.push(`msg ${short} ${d}${rd}`);
    }
  }
```

> This block goes after all other `lines.push(...)` blocks (location, health, device, nextEvent) and before the `if (!lines.length && !ctx.status ...)` check — but since we're changing that check, place the readReceipts block just above the updated early-return check.

Corrected final structure of `buildCtx`:
```
location block → health block → device block → nextEvent block →
readReceipts block →
if (!lines.length && !ctx.status && !Array.isArray(ctx.readReceipts)) return '';
tz / ts header →
return header + lines
```

- [ ] **Step 3: Build to verify TypeScript compiles**

```bash
pnpm run build
```

Expected: no errors

- [ ] **Step 4: Run tests (no regressions)**

```bash
pnpm test
```

Expected: all existing tests pass

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app.ts
git commit -m "feat(ios-channel): inject read receipts into agent context"
```

---

## Task 4: iOS — DeliveryStatus model

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/Message.swift`

- [ ] **Step 1: Add DeliveryStatus enum and field to ChatMessage**

Open `ios/JarvisApp/Sources/JarvisApp/Models/Message.swift`.

After the `// MARK: – Supporting types` comment and before `// MARK: – ChatMessage`, add:

```swift
enum DeliveryStatus: String, Codable {
    case sending    // WS.send() called, no callback yet
    case sent       // WS send callback returned no error
    case delivered  // server sent message_ack
    case failed     // WS send callback returned error
}
```

In the `ChatMessage` struct, change:
```swift
struct ChatMessage: Identifiable {
    let id: String
    let role: Role
    let content: Content
    let timestamp: Date
```
to:
```swift
struct ChatMessage: Identifiable {
    let id: String
    let role: Role
    let content: Content
    let timestamp: Date
    var deliveryStatus: DeliveryStatus = .delivered
```

- [ ] **Step 2: Build to verify no compilation errors**

```bash
cd ios/JarvisApp && xcodegen generate
```

Then open `JarvisApp.xcodeproj` in Xcode and build (⌘B). Expected: builds without errors. The default `.delivered` ensures all existing call sites remain valid.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/Message.swift ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit -m "feat(ios): DeliveryStatus enum on ChatMessage"
```

---

## Task 5: iOS WebSocketClient — outgoing delivery tracking

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`

- [ ] **Step 1: Add updateDeliveryStatus helper**

Inside `WebSocketClient`, after the `// MARK: – Private` comment, add:

```swift
private func updateDeliveryStatus(_ id: String, _ status: DeliveryStatus) {
    guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[idx].deliveryStatus = status
    onMessagesChanged?(messages)
}
```

- [ ] **Step 2: Update send() to use clientMessageId and track status**

Find the `func send(text:timezone:status:attachments:)` method. Replace the section that calls `ws.send` and appends to messages:

```swift
// OLD:
guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
ws.send(.data(data)) { if let e = $0 { print("WS send(message) failed: \(e)") } }
isTyping = true
let ts = Date()
if !text.isEmpty {
    messages.append(.text(UUID().uuidString, role: .user, text: text, timestamp: ts))
}
```

Replace with:

```swift
let clientMsgId = UUID().uuidString
payload["clientMessageId"] = clientMsgId
guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
isTyping = true
let ts = Date()
if !text.isEmpty {
    var msg = ChatMessage.text(clientMsgId, role: .user, text: text, timestamp: ts)
    msg.deliveryStatus = .sending
    messages.append(msg)
}
ws.send(.data(data)) { [weak self] error in
    Task { @MainActor [weak self] in
        self?.updateDeliveryStatus(clientMsgId, error == nil ? .sent : .failed)
    }
}
```

- [ ] **Step 3: Handle message_ack in handleIncoming**

In `handleIncoming`, after the `feedback_ack` block:

```swift
// --- Message ack (server confirmed receipt of user message) ---
if t == "message_ack",
   let clientMsgId = obj["clientMessageId"] as? String {
    updateDeliveryStatus(clientMsgId, .delivered)
    return
}
```

- [ ] **Step 4: Build in Xcode**

Build (⌘B). Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift
git commit -m "feat(ios): outgoing delivery tracking — sending→sent→delivered"
```

---

## Task 6: iOS WebSocketClient — incoming read receipts

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`

- [ ] **Step 1: Add dedup set and callback**

In the `WebSocketClient` property block, after `@ObservationIgnored private var pendingApnsToken`:

```swift
@ObservationIgnored private var sentReadIds: Set<String> = []

/// Callback to notify UI layer that an assistant message should trigger a read receipt.
/// Set by ChatView. Not called directly — WebSocketClient calls sendMessageRead via this.
@ObservationIgnored var onReadReceiptNeeded: ((String) -> Void)?
```

- [ ] **Step 2: Add sendMessageDelivered and sendMessageRead methods**

After `sendContextResponse`, add:

```swift
func sendMessageDelivered(_ messageId: String, conversationId: UUID?) {
    guard let ws = task, isConnected else { return }
    var payload: [String: Any] = ["type": "message_delivered", "messageId": messageId]
    if let cid = conversationId { payload["conversationId"] = cid.uuidString }
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    ws.send(.data(data)) { if let e = $0 { print("WS send(message_delivered) failed: \(e)") } }
}

func sendMessageRead(_ messageId: String, conversationId: UUID?) {
    guard sentReadIds.insert(messageId).inserted else { return }
    guard let ws = task, isConnected else {
        sentReadIds.remove(messageId)
        return
    }
    var payload: [String: Any] = ["type": "message_read", "messageId": messageId]
    if let cid = conversationId { payload["conversationId"] = cid.uuidString }
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    ws.send(.data(data)) { if let e = $0 { print("WS send(message_read) failed: \(e)") } }
}
```

- [ ] **Step 3: Auto-send message_delivered in route()**

In `route(_ message:convId:)`, after `if messages.contains(where: { $0.id == message.id }) { return }` and before `messages.append(message)`, add:

```swift
if message.role == .assistant {
    sendMessageDelivered(message.id, conversationId: conversationId)
}
```

- [ ] **Step 4: Build in Xcode**

Build (⌘B). Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift
git commit -m "feat(ios): sendMessageDelivered/Read + auto-delivered on route"
```

---

## Task 7: iOS MessageCache — persist deliveryStatus

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/MessageCache.swift`

- [ ] **Step 1: Add deliveryStatus field to CachedMessage**

In `private struct CachedMessage: Codable`, add after `statusKind`:

```swift
let deliveryStatus: String?   // "sending"|"sent"|"delivered"|"failed"|nil
```

- [ ] **Step 2: Restore deliveryStatus on load**

In the `load` function, after `let role: ChatMessage.Role` switch, add a helper:

```swift
let restoredStatus: DeliveryStatus = {
    switch cm.deliveryStatus {
    case "sent": return .sent
    case "failed": return .failed
    default: return .delivered  // sending/nil → delivered (past session = done)
    }
}()
```

For each `return .text(...)`, `.image(...)`, `.file(...)`, etc. factory call in the switch, append `with { $0.deliveryStatus = restoredStatus }` — but since `ChatMessage` is a struct, use direct assignment after creation. Replace each factory call with a two-step:

```swift
case "text":
    guard let t = cm.text else { return nil }
    var msg = ChatMessage.text(cm.id, role: role, text: t, timestamp: cm.timestamp)
    msg.deliveryStatus = restoredStatus
    return msg
```

Apply the same pattern for `"image"`, `"file"`, `"action"`, `"status"` cases — each gets `var msg = ...` then `msg.deliveryStatus = restoredStatus` then `return msg`.

- [ ] **Step 3: Persist deliveryStatus on save**

In the `save` function, each `CachedMessage(id: msg.id, role: role, kind: ...)` initializer call needs the new field. Add `deliveryStatus: msg.deliveryStatus.rawValue` to every `CachedMessage(...)` init call in the `switch msg.content` block.

Example for the `.text` case:
```swift
case .text(let t):
    return CachedMessage(id: msg.id, role: role, kind: "text",
                         text: t, imageFile: nil, filename: nil, timestamp: msg.timestamp,
                         fileName: nil, fileSize: nil, fileMimeType: nil, fileUrl: nil,
                         buttons: nil, actionAnswered: nil, actionSelectedId: nil,
                         statusLevel: nil, statusKind: nil,
                         deliveryStatus: msg.deliveryStatus.rawValue)
```

Apply to all 5 cases.

- [ ] **Step 4: Build in Xcode**

Build (⌘B). Expected: no errors. The `CachedMessage` memberwise init requires all fields — compiler will catch any missed cases.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/MessageCache.swift
git commit -m "feat(ios): persist DeliveryStatus in MessageCache"
```

---

## Task 8: iOS MessageBubble — checkmark icons

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/MessageBubble.swift`

- [ ] **Step 1: Add delivery status view**

Open `MessageBubble.swift`. Find the user bubble timestamp line. The exact location depends on current layout — search for `timestamp` display near user bubble. Add a `deliveryStatusView` computed property to the `MessageBubble` struct:

```swift
@ViewBuilder
private var deliveryStatusIcon: some View {
    if message.role == .user {
        Group {
            switch message.deliveryStatus {
            case .sending:
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.5))
            case .sent:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent.opacity(0.7))
            case .delivered:
                HStack(spacing: -3) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent.opacity(0.7))
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }
}
```

- [ ] **Step 2: Integrate into bubble layout**

Find where the timestamp is rendered for user messages (search for `.caption` or `timestamp` in the file). Add `deliveryStatusIcon` inline next to the timestamp in an `HStack`:

```swift
HStack(spacing: 3) {
    Text(message.timestamp, style: .time)
        .font(.caption2)
        .foregroundStyle(Theme.textSecondary)
    deliveryStatusIcon
}
```

The exact integration point depends on the existing bubble layout. The icon must only appear for `role == .user` — the computed property already guards this.

- [ ] **Step 3: Build in Xcode, visually inspect**

Build (⌘B). Run in Simulator. Send a message — bubble should show clock icon briefly (`.sending`), then single checkmark (`.sent`), then double checkmark after server ack (`.delivered`).

Note: `.delivered` won't appear until server-side Task 2 is deployed. You can simulate by temporarily setting status to `.delivered` in `send()` to verify the double-checkmark renders.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/MessageBubble.swift
git commit -m "feat(ios): WhatsApp-style delivery checkmarks on user bubbles"
```

---

## Task 9: iOS ChatView — read receipt trigger on assistant messages

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

- [ ] **Step 1: Add read receipt trigger in message list**

In `ChatView`, find the `ForEach(messages)` or equivalent list rendering loop. For assistant role messages, add `.onAppear`:

```swift
ForEach(messages) { message in
    MessageBubble(message: message)
        .onAppear {
            if message.role == .assistant {
                wsClient.sendMessageRead(message.id, conversationId: wsClient.conversationId)
            }
        }
}
```

> The dedup is handled server-side in `sentReadIds` — `sendMessageRead` silently ignores already-sent IDs. No extra state needed in ChatView.

- [ ] **Step 2: Build in Xcode**

Build (⌘B). Expected: no errors.

- [ ] **Step 3: Smoke test in Simulator**

1. Connect to the server
2. Send a message
3. Receive a reply
4. Check server logs — should see `message_delivered` and `message_read` events logged (add a `log('read receipt: ...')` call in Task 2 if not already there)

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "feat(ios): onAppear read receipt for assistant messages"
```

---

## Self-Review

### Spec coverage

| Spec requirement | Covered by |
|-----------------|-----------|
| `DeliveryStatus` enum (sending/sent/delivered/failed) | Task 4 |
| `clientMessageId` in outgoing WS payload | Task 5 |
| `message_ack` → `.delivered` on iOS | Task 5 |
| WS send callback `.sent` / `.failed` | Task 5 |
| `sendMessageDelivered` auto-called on `route()` | Task 6 |
| `sendMessageRead` called from UI `.onAppear` | Task 9 |
| Dedup `sentReadIds` set | Task 6 |
| `message_delivered` / `message_read` server handlers | Task 2 |
| `message_ack` sent after `onInbound` | Task 2 |
| `data/ios-read-receipts.json` persistence | Task 2 |
| Context injection in `context_response` | Task 3 |
| `buildCtx` read receipts section | Task 3 |
| MessageCache persist `deliveryStatus` | Task 7 |
| WhatsApp checkmarks in MessageBubble | Task 8 |
| Only `role == .user` shows checkmarks | Task 8 |

### Type consistency

- `DeliveryStatus` defined in Task 4, used in Tasks 5, 6, 7, 8 — consistent
- `sendMessageRead(_ messageId: String, conversationId: UUID?)` defined in Task 6, called in Task 9 — consistent
- `ReadReceipt` interface defined in Task 1, used in Tasks 2, 3 — consistent
- `clientMessageId` key used in Task 5 (iOS send) and Task 2 (server ack) — consistent

### Placeholder check

- Task 8 Step 2: "exact integration point depends on current layout" — intentional, bubble layout is complex and varies. The instruction is specific enough (find timestamp, wrap in HStack with deliveryStatusIcon).
- All other steps have complete code.
