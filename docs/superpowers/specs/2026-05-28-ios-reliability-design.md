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

Two related gaps:

1. **`deliveryStatus` defaults to `.delivered`** ([`Message.swift:55`](../../ios/JarvisApp/Sources/JarvisApp/Models/Message.swift#L55)). On app relaunch from `MessageCache`, any message that was previously `.sending` / `.sent` / `.failed` comes back as `.delivered` — a lie.
2. **Tests missing:** no offline-queue, no video attachments, no `request_context` end-to-end on iOS side, no auto-context-merge on `send()`.

## Goals

- **Never drop a user message.** Every `send()` produces an entry in the local outbox, regardless of WS state.
- **Persist delivery status across app launches.** `MessageCache` round-trips `deliveryStatus`.
- **Retry on reconnect** with exponential backoff (already present on server outbound; needed on iOS outbound).
- **Tests:** offline queue, replay on reconnect, persisted status, context-pull end-to-end (iOS side), auto-context-merge.

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

### Persisted Delivery Status

Two changes:

1. `Message.swift` — change `var deliveryStatus: DeliveryStatus = .delivered` to no default, force callers to set it explicitly. For assistant messages, init to `.delivered`. For user messages, init via the send path.

2. `MessageCache` — add `deliveryStatus` to `CachedMessage`:

```swift
struct CachedMessage: Codable {
    let id: String
    let role: ChatMessage.Role
    let kind: Kind                   // .text, .image, .file, .action
    let text: String?
    let timestamp: Date
    let imagePath: String?
    let fileInfo: FileInfo?
    let deliveryStatus: DeliveryStatus  // NEW
}
```

On load, status round-trips. Migration: if missing key in JSON, default to `.delivered` for assistant rows and `.sent` for user rows (best-effort guess for legacy cache).

### Auto-Context-Merge on Send

Today, `WebSocketClient.send()` accepts an optional `context: [String: Any]?`. `AppCoordinator.sendCurrent()` should pass a minimal context dict **on every send** containing at minimum:

- `timestamp` (always)
- `timezone` (always)
- `location` (if `settings.useLocation` AND fresh location available — older than 15min counts as not-fresh)
- `device.battery` (always — cheap, useful for proactive features)

Heavy fields (`health`, `calendar`) remain pull-only via `request_context`.

`ContextBuilder.build()` already supports field selection. New `ContextBuilder.buildAutoSend(...)` returns the minimal subset:

```swift
static func buildAutoSend(settings: AppSettings, location: LocationManager) -> [String: Any] {
    var ctx: [String: Any] = [
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "timezone": TimeZone.current.identifier,
    ]
    if settings.useLocation,
       let loc = location.lastLocation,
       Date().timeIntervalSince(loc.timestamp) < 900 {
        ctx["location"] = [
            "lat": (loc.coordinate.latitude * 1e4).rounded() / 1e4,
            "lon": (loc.coordinate.longitude * 1e4).rounded() / 1e4,
            "city": location.cityName ?? "",
        ]
    }
    UIDevice.current.isBatteryMonitoringEnabled = true
    let battery = UIDevice.current.batteryLevel
    if battery >= 0 { ctx["device"] = ["battery": Int((battery * 100).rounded())] }
    return ctx
}
```

Wired in `AppCoordinator.sendCurrent()` before calling `ws.send(...)`.

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
| `MessageCacheDeliveryStatusTest` | round-trip `.sending`, `.sent`, `.delivered`, `.failed` through save/load |
| `MessageCacheLegacyMigrationTest` | JSON without `deliveryStatus` key loads with `.delivered` (assistant) / `.sent` (user) defaults |
| `ContextBuilderAutoSendTest` | matrix: useLocation off → no location key; stale location → no key; fresh → present; battery always present when level >= 0 |
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

- `MessageCache` v2 schema: bumps `index.json` to include `deliveryStatus`. Legacy `index.json` reads with defaults.
- `OutboxStore` is new — empty on first launch, no migration.
- No server schema changes (only dedup state, in-memory).

## Open Questions

1. **30s stale-sent timeout** — should it be shorter (10s) to surface failures faster, or longer (60s) to tolerate slow agents? Proposal: 30s, configurable later.
2. **Manual retry UI** — red `.failed` indicator is currently just a static icon. Need to make tappable + add haptic. Proposal: tappable with `Theme.hapticMedium()`.
3. **Outbox visibility surface** — should a small badge appear in the header (e.g. "3 ↑" pending) when outbox > 0? Proposal: yes, show a tiny number under the left status dot when `outbox.entries.count > 0`.

## Dependencies

None on other in-flight specs. Independent of UI-unified-navigation (no header changes here beyond optional outbox badge).
