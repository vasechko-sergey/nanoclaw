# iOS — Reliability: Offline Send Queue, Persisted Delivery Status, Context Tests

**Date:** 2026-05-28
**Scope:** iOS app (`ios/JarvisApp/`) WebSocket client + tests, no server changes required

## Problem

The current iOS app drops outbound messages on the floor when offline. From [`WebSocketClient.swift:119`](../../ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift#L119):

```swift
func send(text: String, ...) {
    guard let ws = task, isConnected else { return }
    ...
}
```

Symptom: user types a message while train tunnel / lift / spotty wifi → tap send → nothing visible in the message list → message lost. No `failed` status, no retry, no warning. This violates the "guaranteed delivery" requirement.

Tests missing: no offline-queue, no `request_context` end-to-end on iOS side, no auto-context-merge coverage (the feature is implemented but unverified).

**Already in place** (verified during spec review — do NOT re-implement):

- `MessageCache` round-trips `deliveryStatus` for `.sent` / `.failed` / `.delivered` ([`MessageCache.swift:56-62`](../../ios/JarvisApp/Sources/JarvisApp/Services/MessageCache.swift#L56)). Legacy entries without the key default to `.delivered`. `.sending` collapses to `.delivered` on reload (treats interrupted sends as completed in past sessions — this is a design choice we keep; the outbox is the source of truth for genuinely unsent messages, and on next launch the outbox will re-flush).
- `AppCoordinator.sendMessage` calls `ContextBuilder.build(fields: [])` on every send ([`AppCoordinator.swift:88`](../../ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift#L88)), pushing the full inline snapshot (location/health/calendar/device/timestamp/timezone) honoring privacy toggles. No new builder needed.

## Goals

- **Never drop a user message.** Every `send()` produces an entry in the local outbox, regardless of WS state.
- **Retry on reconnect** with exponential backoff (already present on server outbound; needed on iOS outbound).
- **Server-side dedup** of repeated `clientMessageId` (so retry doesn't double-deliver).
- **Tests** for: offline queue, reconnect replay, existing-but-untested round-trip of `deliveryStatus` through `MessageCache`, existing-but-untested auto-context-merge via `ContextBuilder.build`, `request_context` end-to-end on iOS side.

## Non-Goals

- Server-side outbound queue changes (already handles `pendingMessages` correctly per device).
- Cryptographic message-integrity or dedup beyond `clientMessageId`.
- Outbox UI surface beyond per-message `DeliveryChecks` indicator.
- Backpressure when the outbox grows unbounded (we cap at 100, drop oldest with warning row).

## Architecture

### Outbox Store

New service `OutboxStore` (Documents/Outbox/queue.json) — persisted FIFO of unsent payloads.

```swift
struct OutboxEntry: Codable {
    let id: String                  // clientMessageId
    let conversationId: UUID?
    let createdAt: Date
    var lastAttempt: Date?
    var attempts: Int = 0
    let payload: Data               // JSON-serialized WS payload
    let textPreview: String         // for UI rendering when ws.task is nil
    let hasAttachments: Bool
}

@Observable @MainActor final class OutboxStore {
    var entries: [OutboxEntry] = []   // sorted by createdAt asc
    private let url: URL              // Documents/Outbox/queue.json
    private let maxEntries = 100

    func enqueue(_ entry: OutboxEntry)
    func remove(_ id: String)
    func bumpAttempt(_ id: String)
    func load()                       // on init
    func save()                       // debounced after every mutation
}
```

### Send Flow (Rewired)

```swift
func send(text: String, timezone: String, ...) {
    let clientMsgId = UUID().uuidString
    let ts = Date()
    let payload: [String: Any] = [
        "type": "message",
        "text": text,
        "timezone": timezone,
        "clientMessageId": clientMsgId,
        // attachments, context, conversationId...
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

    // 1. Append to local UI (sending)
    var msg = ChatMessage.text(clientMsgId, role: .user, text: text, timestamp: ts)
    msg.deliveryStatus = .sending
    messages.append(msg)
    onMessagesChanged?(messages)

    // 2. Enqueue locally — survives crash, offline, anything
    outbox.enqueue(OutboxEntry(
        id: clientMsgId,
        conversationId: conversationId,
        createdAt: ts,
        payload: data,
        textPreview: text,
        hasAttachments: !attachments.isEmpty,
    ))

    // 3. Attempt immediate send
    flushOutbox()
}
```

### Flush Loop

```swift
private func flushOutbox() {
    guard let ws = task, isConnected else { return }
    let snapshot = outbox.entries  // copy to avoid mutation-during-iteration
    for entry in snapshot {
        outbox.bumpAttempt(entry.id)
        ws.send(.data(entry.payload)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error == nil {
                    self.updateDeliveryStatus(entry.id, .sent)
                    // .delivered comes later via message_ack; entry stays
                    // in outbox until then for re-send-on-reconnect safety.
                } else {
                    self.updateDeliveryStatus(entry.id, .failed)
                    // do NOT remove — retry on reconnect or manual retry tap
                }
            }
        }
    }
}
```

On `message_ack` from server → `outbox.remove(clientMessageId)` AND `updateDeliveryStatus(.delivered)`.

On reconnect (existing `doConnect` success path) → `flushOutbox()` runs automatically.

### Retry Strategy

- **Auto-retry:** every reconnect triggers a full `flushOutbox`. WS-level send failures bump `attempts` counter.
- **Backoff:** if `attempts >= 5` AND `lastAttempt` is within 60s → skip this entry for 60s. Prevents tight loops when the server NAKs.
- **Manual retry:** tapping the red `failed` indicator on a row calls `flushOutbox(entry.id)` for just that one.
- **Drop policy:** outbox capped at 100. If full on enqueue, drop oldest entry **only if its status is `.failed`**. If all 100 are `.sending` / `.sent`, refuse enqueue and surface a system row "Очередь переполнена, проверьте соединение" — does not happen in practice with healthy reconnect.

### Delivery Status — Existing Behavior

`MessageCache` already persists `deliveryStatus` through `CachedMessage` and restores via `restoredStatus` in `MessageCache.load(from:)` (see [`MessageCache.swift:56-62`](../../ios/JarvisApp/Sources/JarvisApp/Services/MessageCache.swift#L56)).

What this spec **does not change**:

- The default `var deliveryStatus: DeliveryStatus = .delivered` on `Message.swift:55` stays. Assistant messages legitimately default to `.delivered`. User messages get their status set in the send path before append.
- `.sending` collapses to `.delivered` on reload. This is correct: anything genuinely unsent lives in the outbox, not in cache; cache is "what the UI showed last". The outbox re-flushes those entries on next reconnect.

What this spec **adds** (tests only):

- `MessageCacheDeliveryStatusRoundTripTest` — explicit coverage for the existing behavior so future refactors don't break it.

### Auto-Context-Merge — Existing Behavior

Already wired. `AppCoordinator.sendMessage` ([`AppCoordinator.swift:88`](../../ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift#L88)) calls:

```swift
let ctx = ContextBuilder.build(
    fields: [],         // empty = all available fields
    settings: settings,
    location: location,
    health: health,
    calendar: calendar,
)
ws.send(text:..., context: ctx)
```

`ContextBuilder.build` honors privacy toggles (`useLocation` / `useHealth` / `useCalendar`) and always appends `timestamp` + `timezone`. Battery is bundled under the `device` block.

What this spec **does not change**: the behavior itself.

What this spec **adds**:

- `ContextBuilderAutoSendMatrixTest` — covers the matrix: useLocation off → no location key; stale location → no key; fresh → present; battery always present when `level >= 0`; timezone always present.
- Doc note in `ios-app.ts` confirming that the inline context block already covers reliability needs (no new path needed for "always-send a minimum" — the path exists).

**Open question:** today `ContextBuilder` sends the location even when stale (no 15min guard — that 15min cache exists in `LocationManager`, not the builder). Decision needed: tighten in the builder (preferred — defence in depth) or leave to `LocationManager.lastLocation` to be nil-on-stale. Proposal: tighten in the builder during the test pass, since it's a one-line guard.

## Data Flow

```
User taps Send
   │
   ▼
AppCoordinator.sendCurrent()
   │ ctx = ContextBuilder.buildAutoSend(...)
   ▼
WebSocketClient.send(text:..., context: ctx)
   │ append ChatMessage(.sending) to messages
   │ outbox.enqueue(...)
   ▼
flushOutbox()
   │
   ├─ ws.task == nil → no-op (stays in outbox; reconnect will retry)
   │
   ├─ ws.send(...) callback error → updateDeliveryStatus(.failed)
   │                                 outbox.bumpAttempt
   │
   ├─ ws.send(...) callback nil error → updateDeliveryStatus(.sent)
   │                                    outbox keeps entry
   │
   └─ Server emits message_ack
       │
       ▼
       updateDeliveryStatus(.delivered)
       outbox.remove(clientMessageId)
       MessageCache.save(...)
```

## Error Handling

| Situation | Behaviour |
|---|---|
| App crash mid-send | Outbox persisted to disk → next launch reloads + `flushOutbox()` on first reconnect |
| Server NAKs a message (malformed) | Server-side, no NAK protocol today. If added later, mark `.failed` and surface inline error |
| Outbox grows to 100 | Oldest `.failed` entry dropped with a system row warning |
| `message_ack` for unknown clientMessageId | Ignored (idempotent); no UI change |
| `ws.send()` succeeds but TCP layer loses bytes | Server never sends `message_ack` → entry stays `.sent` indefinitely. Mitigation: 30s timeout — if `.sent` without `.delivered`, bump to `.failed` on next reconnect cycle, re-flush |
| Battery level unavailable | omit `device.battery` (already guarded by `level >= 0`) |
| Location stale | omit `location` (15min freshness gate above) |

## Testing

**Unit tests (`Tests/JarvisAppTests/`):**

| Test | Asserts |
|---|---|
| `OutboxStoreEnqueueTest` | enqueue → persisted to disk → reload reproduces entry |
| `OutboxStoreCapTest` | enqueueing 101st entry: with one .failed at front, oldest .failed dropped; with none .failed, refused |
| `OutboxBackoffTest` | entry with 5+ attempts in last 60s skipped by flush; after 60s included again |
| `MessageCacheDeliveryStatusRoundTripTest` | round-trip `.sent`, `.delivered`, `.failed` through save/load via existing `CachedMessage.deliveryStatus` field; `.sending` collapses to `.delivered` per spec note |
| `MessageCacheLegacyMigrationTest` | JSON without `deliveryStatus` key loads with `.delivered` default (existing fallback in `MessageCache.load`) |
| `ContextBuilderAutoSendMatrixTest` | matrix on existing `ContextBuilder.build(fields: [])`: useLocation off → no location key; stale location → no key (after the builder-level 15min guard is added); fresh → present; timezone always present; battery present when level >= 0 |
| `WebSocketClientOfflineSendTest` | call `send()` with `task = nil` → message appears in `messages` as `.sending`, outbox count = 1, no crash |
| `WebSocketClientReconnectFlushTest` | enqueue 3 offline messages, simulate reconnect → all three sent in order, statuses go to `.sent` then `.delivered` on ack |
| `WebSocketClientStaleSentTest` | mark entry `.sent` 31s ago, run flush → status bumps to `.failed`, entry re-attempted |

**Server-side tests (extend `src/channels/`):**

| Test | Asserts |
|---|---|
| `ios-app.message-ack.test.ts` | NEW — server emits `message_ack` with same `clientMessageId` after `onInbound` resolves; iOS deps on this contract |
| `ios-app.duplicate-clientmsgid.test.ts` | NEW — sending the same `clientMessageId` twice (post-reconnect double-flush) does NOT produce two inbound entries — server dedupes per device |

The duplicate-dedup feature is **new server logic** — needed because the iOS retry can legitimately re-send a payload whose ack we missed. Implementation: add `processedClientMsgIds: Map<platformId, LRUSet>` (size 500) to `IosWsHandlerState`. On `onInbound`, check + add; second occurrence emits `message_ack` immediately without forwarding to the agent.

**UI tests:**

| Test | Steps |
|---|---|
| `OfflineSendUITest` | Disable server (kill WS in test harness); type + send; assert row visible with spinner; assert outbox.json on disk; re-enable; assert checkmark appears within 5s |
| `FailedRetryTapTest` | Force `.failed`; tap red indicator; assert flush attempted |

## Migration

- `MessageCache` schema unchanged — `deliveryStatus` already present in `CachedMessage` and legacy fallback already there.
- `OutboxStore` is new — empty on first launch, no migration.
- No server schema changes (only dedup state, in-memory).

## Open Questions

1. **30s stale-sent timeout** — should it be shorter (10s) to surface failures faster, or longer (60s) to tolerate slow agents? Proposal: 30s, configurable later.
2. **Manual retry UI** — red `.failed` indicator is currently just a static icon. Need to make tappable + add haptic. Proposal: tappable with `Theme.hapticMedium()`.
3. **Outbox visibility surface** — should a small badge appear in the header (e.g. "3 ↑" pending) when outbox > 0? Proposal: yes, show a tiny number under the left status dot when `outbox.entries.count > 0`.

## Dependencies

None on other in-flight specs. Independent of UI-unified-navigation (no header changes here beyond optional outbox badge).
