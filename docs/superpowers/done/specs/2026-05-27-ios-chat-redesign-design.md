# iOS Chat Redesign — Design Spec

**Date:** 2026-05-27
**Scope:** `ios/JarvisApp/` — chat UI redesign, archive removal, delivery indicator polish, busy-state model, connection stability, conversation list as left drawer.

## Goals

1. Remove the dead "archived chat" read-only flow. Any past conversation must be openable as the active conversation in one tap (Telegram-style switching).
2. Replace the WhatsApp-style overlapping SF Symbol checkmarks with custom-drawn delivery indicators that fit the JARVIS visual language.
3. Make the "Jarvis is thinking" indicator reliable — it must show during the entire span between the user's send and the assistant's final reply, not just during server-emitted `typing_*` events.
4. Make the WebSocket connection visibly stable — survive network changes, app foreground transitions, and dead sockets without user intervention.
5. Replace the bubble-based chat with a bubbleless "Hybrid A" layout (system font, avatar-dot + meta-row + body, hairline separators) so the app stops feeling like a generic ChatGPT clone.
6. Give the conversation list a discoverable, one-gesture entry point from the chat (hamburger + edge-swipe drawer).
7. Refresh secondary chrome (header, input bar, empty state, banners, separators) to match the new visual language.

## Non-Goals

- No new visual identity (colors, brand, orb concept stay).
- No protocol changes on the host side (`src/channels/ios-app.ts`) beyond what `URLSessionWebSocketTask.sendPing` already does at the transport level. Server-side approval routing, OneCLI, etc. — out of scope.
- No new conversation features (forking, exporting, sharing). Switching only.
- No multi-platform considerations (Android, web, macOS) — iOS only.

## Architecture

### Files Touched

| File | Action |
|------|--------|
| `Sources/JarvisApp/Components/MessageBubble.swift` | Rename → `MessageRow.swift`. Full rewrite to bubbleless layout. |
| `Sources/JarvisApp/Components/MiniOrbView.swift` | Add size-conditional particle overlay for `.processing` mood (no enum changes). |
| `Sources/JarvisApp/Components/UnifiedInputBar.swift` | Pill style refresh, send-button refresh, identifier additions. |
| `Sources/JarvisApp/Components/EmptyStateView.swift` | Visual refresh — big orb, hairline suggestion pills. |
| `Sources/JarvisApp/Components/ConnectionBanner.swift` | Collapse into hairline strip; placed under header. |
| `Sources/JarvisApp/Components/AttachmentBar.swift` | Minor: corner radius / padding sync with new tokens. |
| `Sources/JarvisApp/Components/DeliveryChecks.swift` | **New file** — custom `Shape`-based checkmarks. |
| `Sources/JarvisApp/Views/ChatView.swift` | Header refresh, hamburger button, drawer overlay, `ThinkingRow` replaces `TypingIndicator`, edge-swipe gesture. |
| `Sources/JarvisApp/Views/ConversationListView.swift` | Render path changed: now drawer content invoked from `ChatView`. Row tap → `.open(conv)` regardless of active state. Drawer footer with settings link. |
| `Sources/JarvisApp/Views/ArchivedChatView.swift` | **Delete file.** |
| `Sources/JarvisApp/Views/SettingsView.swift` | Remove "История" → `ConversationListView` `NavigationLink` section. |
| `Sources/JarvisApp/Views/OrbHomeView.swift` | Add "Продолжить: <last conv>" pill under micro-orb. |
| `Sources/JarvisApp/Services/WebSocketClient.swift` | Heartbeat timer, `isBusy` derived state, `lastUserSentAt`/`lastAssistantAt`, `handleScenePhase`, `forceReconnect`, `thinkingDetail`. |
| `Sources/JarvisApp/Services/ConnectivityMonitor.swift` | Add `onSatisfied` callback (trigger reconnect on path change). |
| `Sources/JarvisApp/JarvisApp.swift` | Wire `@Environment(\.scenePhase)` → `ws.handleScenePhase`. |
| `Sources/JarvisApp/Utility/Theme.swift` | Add tokens: `rowPadV`, `rowPadH`, `metaFont`, `avatarDotSize`, `hairlineColor`, `drawerWidth`, `inputBarRadius`. Remove (or alias for legacy): `userBubble`, `assistantBubble`, `userBubbleBorder`, `assistantBubbleBorder`, `bubbleRadius`. `messagePadH`/`messagePadV` retained for inline cards (file, action). |
| `Sources/JarvisApp/Models/Message.swift` | No structural change (DeliveryStatus enum reused). |
| `Sources/JarvisUITests/JarvisUITests.swift` | Update XCUI predicates after identifier renames; add drawer + thinking tests. |

### New Entities

- (No new enum.) `OrbMood` is reused as-is (`heroic/welcoming/ready/listening/processing/speaking/calm/error`); `MiniOrbView` gets a new size-conditional particle overlay for `.processing`.
- **`struct CheckmarkShape: Shape`** (`DeliveryChecks.swift`) — path-based checkmark.
- **`struct DeliveryChecks: View`** (`DeliveryChecks.swift`) — switches by `DeliveryStatus`, animates `sent → delivered` transition.
- **`struct ThinkingRow: View`** (inside `MessageRow.swift` or sibling) — orb-tiny + animated dots label.
- **`struct DrawerContent: View`** (inside `ConversationListView.swift`) — extracted content body so `ChatView` can host it.

### State Changes

In `WebSocketClient`:

```swift
@ObservationIgnored private var heartbeatTimer: Timer?
@ObservationIgnored private var lastPongAt: Date = .distantPast
@ObservationIgnored private let pingInterval: TimeInterval = 25
@ObservationIgnored private let pongTimeout: TimeInterval = 35

var lastUserSentAt: Date? = nil
var lastAssistantAt: Date? = nil
var thinkingDetail: String? = nil   // last status message text (kind=system) if < 30s old

var isBusy: Bool {
    if isTyping { return true }
    guard let sent = lastUserSentAt else { return false }
    if let got = lastAssistantAt, got >= sent { return false }
    return Date().timeIntervalSince(sent) < 300   // 5-min timeout
}
```

## Components — Detailed Design

### MessageRow (replaces MessageBubble)

Layout:

```
┌─────────────────────────────────────────────┐
│ ●  JARVIS · 14:32                           │
│    Анализирую базу. Нашёл 3 файла с         │
│    конфликтами зависимостей в package.json. │
│ ─────────────────────────────────────────── │
│ ○  Я · 14:33                           ✓✓   │
│    Покажи список                            │
│ ─────────────────────────────────────────── │
└─────────────────────────────────────────────┘
```

- Avatar-dot: 8×8 circle, top-margin 7pt so it visually aligns with first text line.
  - Assistant: `Theme.accent` (`#54BCC5`) with `shadow(color: .accent.opacity(0.5), radius: 3)`.
  - User: `Color.white.opacity(0.25)`.
- Meta row: SF Mono 10pt, uppercase, tracking 0.5. Left = role label ("JARVIS" / "Я"). Right = `HH:mm` + (user only) `DeliveryChecks`.
- Body: `MarkdownText` for assistant (existing component, no change), `Text` for user. Font size 14pt, line height ~1.45 (`.lineSpacing(2)`).
- Color: `#e0eff1` assistant, white user.
- Hairline separator under each row: `0.5pt rgba(84,188,197,0.05)`. Suppressed on the last visible row.
- Padding: vertical 12pt, horizontal 18pt.
- Long-press → existing `contextMenu` (copy, share, speak, feedback). Preview now renders the bubbleless row.

Variants:

- **Image row** — avatar + meta as above; image `max-width: 240pt, cornerRadius: 10`. No surrounding bubble.
- **File row** — avatar + meta + inline horizontal card `[icon][name + size]`. Card keeps a faint background `accent.opacity(0.04)` so files remain visually distinct from prose. Corner radius 10, padding 10/8.
- **Action row** — avatar + meta + text + `FlowLayout` of buttons (existing). No surrounding bubble. Answered state: capsule with `accent.opacity(0.12)` background + slim checkmark, label.
- **Status row** — full-width hairline-padded block, no avatar, no meta. Single line `[icon] [text]` with level-tinted color. Exception to the avatar-dot rule (system messages).

Transitions:

```swift
.transition(
  .asymmetric(
    insertion: .opacity.combined(with: .offset(y: 8)),
    removal:   .opacity
  )
)
```

No scale animation — text must not visually re-size during insertion.

Accessibility:

- `accessibilityElement(children: .combine)`.
- Label: `"\(role): \(text). \(time)"` (existing format).
- Identifier: `row-user-<id>` / `row-assistant-<id>` (renamed from `bubble-*`).

### DeliveryChecks

`DeliveryChecks.swift`:

```swift
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX * 0.85, y: rect.maxY - 1))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 1))
        }
    }
}
```

States:

| Status | Visual | Notes |
|--------|--------|-------|
| `sending` | ¾ arc of a circle, rotating 360° / 1.2s, stroke `accent.opacity(0.5)`, width 1pt | Replaces `clock` SF Symbol |
| `sent` | Single `CheckmarkShape`, 10×6, stroke `accent.opacity(0.7)`, width 1.3pt, round caps | |
| `delivered` | Two `CheckmarkShape`s in an `HStack(spacing: -3)`, stroke `accent.opacity(0.8)` | Second checkmark fades in over 200ms when transitioning from `sent` |
| `failed` | `Image(systemName: "exclamationmark.circle.fill")` 11pt, red 0.9 | The only state that keeps an SF Symbol — recognisability matters for errors |

Container: `frame(width: 14, height: 10)`. Wrapped in `.animation(.easeOut(duration: 0.2), value: status)` so state transitions are smooth.

Placement: meta-row, after time, user messages only. Hidden for assistant.

Color: all non-failed states use accent teal (not blue/white) — reinforces "Jarvis received" semantics, not "Apple Messages". `failed` is intentionally red for instant recognition.

### ThinkingRow + Busy state

`isBusy` is rendered as a `ThinkingRow` placed in the message scroll, at the same `id = "thinking"` anchor used today. Existing scroll-to-bottom-on-typing logic is rewired to observe `ws.isBusy` instead of `ws.isTyping`.

```swift
if ws.isBusy {
    ThinkingRow(detail: ws.thinkingDetail)
        .id("thinking")
        .transition(.opacity.combined(with: .offset(y: 4)))
}
```

ThinkingRow visual:

```
[orb-tiny 14×14, pulsating]   обдумываю...
```

- Orb: `MiniOrbView(size: 14, mood: .processing)`. Existing `.processing` params (`speed: 3.0, alpha: 0.85, breathAmp: 0.05`) provide the pulse — no per-row animation override needed.
- Label: system 13pt italic, `Theme.accent.opacity(0.7)`. If `ws.thinkingDetail` is set, use that string; otherwise fallback to `"обдумываю"`.
- Trailing animated ellipsis: a `Text` view that cycles `"", ".", "..", "..."` every 350ms using a `.numericText()` content transition. Implemented as a small `@State counter` driving the string.
- Padding: vertical 12pt, horizontal 18pt. No hairline separator below (it's transient).

Server-side typing events still drive `isTyping`. The client signals layered on top:

- `lastUserSentAt` is set in `send(text:...)` immediately after the WS send call.
- `lastAssistantAt` is set in `handleIncoming` whenever a `message` of role `assistant` arrives.
- `thinkingDetail` is set when a status message arrives with `kind == "system"`; cleared 30s later (or when `isBusy` flips to false).
- On disconnect / reconnect, `lastUserSentAt`, `lastAssistantAt`, `isTyping`, `thinkingDetail` all reset to nil/false.
- 5-minute hard timeout on `isBusy` prevents an eternal spinner if the server drops a request.

### Connection Stability

Heartbeat (`WebSocketClient.swift`):

```swift
private func startHeartbeat() {
    heartbeatTimer?.invalidate()
    lastPongAt = Date()
    heartbeatTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tickHeartbeat() }
    }
}

@MainActor
private func tickHeartbeat() {
    guard let ws = task, isConnected else { return }
    if Date().timeIntervalSince(lastPongAt) > pongTimeout {
        forceReconnect(reason: "pong timeout")
        return
    }
    ws.sendPing { [weak self] error in
        Task { @MainActor in
            if error == nil { self?.lastPongAt = Date() }
            else { self?.forceReconnect(reason: "ping failed") }
        }
    }
}

private func forceReconnect(reason: String) {
    print("WS reconnect: \(reason)")
    task?.cancel(with: .goingAway, reason: nil)
    isConnected = false
    isTyping = false
    reconnectDelay = 1
    guard !stopped, let settings else { return }
    doConnect(settings: settings)
}
```

`startHeartbeat()` is invoked from the `auth_ok` handler. `heartbeatTimer?.invalidate()` is called in `disconnect()` and at the start of each `doConnect`.

App lifecycle:

```swift
// JarvisApp.swift
@Environment(\.scenePhase) private var scenePhase
// ...
.onChange(of: scenePhase) { _, new in
    coordinator.ws.handleScenePhase(new)
}
```

```swift
// WebSocketClient.swift
func handleScenePhase(_ phase: ScenePhase) {
    switch phase {
    case .active:
        if !isConnected, !stopped, let settings { doConnect(settings: settings) }
        else if isConnected { tickHeartbeat() }
    case .background, .inactive:
        break   // don't actively disconnect — let iOS suspend us
    @unknown default: break
    }
}
```

Network path:

```swift
// ConnectivityMonitor.swift
var onSatisfied: (() -> Void)?
// in pathUpdateHandler:
if path.status == .satisfied {
    DispatchQueue.main.async { self?.onSatisfied?() }
}
```

```swift
// WebSocketClient.start():
ConnectivityMonitor.shared.onSatisfied = { [weak self] in
    guard let self, !self.isConnected, !self.stopped, let s = self.settings else { return }
    self.doConnect(settings: s)
}
```

Reconnect backoff stays exponential to 30s for genuine server outages; `forceReconnect` resets to 1s for transient issues.

Server side note: `URLSessionWebSocketTask.sendPing` operates at the WebSocket protocol level (`0x9` ping frame). The `ws` Node library on the host responds with pong automatically — no host-side code change required. Verify the existing channel adapter doesn't close idle connections faster than 25s.

ConnectionBanner: collapses into a hairline strip directly under the chat header. Height 28pt when `!isConnected`, 0pt otherwise. Background `red.opacity(0.85)`, white text "Восстанавливаю связь...", left-side pulsing 6×6 dot. Fades to 0 opacity (400ms) on reconnect, then height collapses.

### Conversation List as Left Drawer

ChatView gains drawer infrastructure:

```swift
@State private var drawerOpen = false
@State private var drawerDragOffset: CGFloat = 0
```

Render:

```swift
ZStack(alignment: .leading) {
    mainContent  // header + chat body + input bar

    if drawerOpen {
        Color.black.opacity(0.5)
            .ignoresSafeArea()
            .onTapGesture { withAnimation { drawerOpen = false } }
            .transition(.opacity)
    }

    DrawerContent(store: store) { action in
        handleDrawerAction(action)
        withAnimation { drawerOpen = false }
    }
    .frame(width: Theme.drawerWidth)
    .offset(x: drawerOpen
            ? drawerDragOffset
            : -Theme.drawerWidth + drawerDragOffset)
    .gesture(dragToClose)
}
.gesture(edgeSwipeToOpen)
.animation(.spring(duration: 0.35, bounce: 0.05), value: drawerOpen)
```

Gestures:

- `edgeSwipeToOpen`: `DragGesture(minimumDistance: 10)` — if `value.startLocation.x < 24 && value.translation.width > 0`, track. On end, if `width > 80`, open.
- `dragToClose`: on drawer content — `value.translation.width < -60` on end → close.

Header redesign:

```
[hamburger 24×24] [orb-mini 22 with status overlay] [JARVIS brand, flex] [gear]
```

- Hamburger: three rectangles (18/14/18 pt wide × 1.5pt tall, 4pt gap), color `Theme.accentMedium`. Tap area `Theme.minTapSize`.
- Orb-mini: `MiniOrbView(size: 22, mood: <derived>)`. Connection state overlays as a tiny 6×6 dot at the bottom-right of the orb (`Theme.online` / `Theme.offline`). Replaces the existing standalone profile-status button.
- Brand "JARVIS": unchanged tap behaviour (→ home).
- Gear: unchanged.

Tap on orb-mini → opens `ProfileView` sheet (preserves the old profile-button behaviour without occupying a dedicated slot).

DrawerContent:

- Drawer header row: title "Диалоги" + `+` button (new chat).
- Search field — same as today.
- Sections (Закреплённые / Сегодня / Вчера / Эта неделя / Ранее) — same grouping logic.
- Row:
  - Active indicator: 6×6 dot. Active = `Theme.accent` with glow. Inactive = `accentSubtle.opacity(0.3)`.
  - Title: system 14pt, regular (medium if active).
  - Preview: 11pt, `textTertiary`, 1 line, dimmed.
  - Meta line: SF Mono 9pt, uppercase. Format: `"14:32 · 12 СООБЩ."`.
  - Background: `Theme.accent.opacity(0.08)` if active, clear otherwise.
- Swipe actions (pin, delete) — unchanged.
- Row tap (any conversation, active or not): `onAction(.open(conv))` then close drawer.
- Footer (sticky at bottom): hairline `[⚙ Настройки]` link — secondary path to settings while drawer is open.

Removed:

- `ArchivedChatView.swift` file deleted.
- `ConversationListView.archivedConversation` state, `fullScreenCover` modifier deleted.
- `SettingsView` "История" section + `NavigationLink` deleted.

Result: `.open(conv)` (existing `AppCoordinator.handleAction` path) is the single switch flow.

### MiniOrbView Moods

`MiniOrbView`'s `OrbMood` enum already exists with these cases: `heroic, welcoming, ready, listening, processing, speaking, calm, error`. We do **not** rename the enum — existing call sites in `OrbInputBar.swift`, `UnifiedInputBar.swift`, `MessageBubble.swift`, `SettingsView.swift`, `ContentView.swift`, and `OrbView.swift` keep using these names.

What we add: a new animation overlay for `.processing` so the larger header orb (size 22) renders a particle rotation (3 small dots circling at radius = orb radius + 4) in addition to the current breathing scale. Small-size processing (the 14pt orb inside `ThinkingRow`) keeps the existing pulse — particles are too small to read at that size, so they're conditional on `size >= 20`.

ChatView header mood binding (uses existing cases):

```swift
let mood: OrbMood = {
    if !ws.isConnected               { return .error }
    if ws.isBusy                     { return .processing }
    if coordinator.speech.isSpeaking { return .speaking }
    if speech.isRecording            { return .listening }
    return .calm
}()
MiniOrbView(size: 22, mood: mood)
```

`ThinkingRow` uses `MiniOrbView(size: 14, mood: .processing)` — same enum case, smaller size, no particle overlay.

No call-site changes elsewhere — only `MiniOrbView.swift` itself gets the new particle overlay conditional on size.

### UnifiedInputBar Polish

- Pill background: `Color.white.opacity(0.04)` with `0.5pt` border `Theme.accent.opacity(0.15)`.
- Corner radius: `Theme.inputBarRadius` (22).
- Placeholder: `"Спросить Jarvis..."`, 13pt, `Color.white.opacity(0.4)`.
- `+` attachment button: stays inline inside the pill, tap area trimmed to 32×32 so the pill stretches farther.
- Send button: 36×36 circle, `Theme.accent` fill, `↑` 16pt bold in `Theme.background` colour.
- Mic ↔ stop ↔ send transition: `.contentTransition(.symbolEffect(.replace))`.
- Command suggestions popover: hairline 0.5pt separators between rows instead of full-opacity dividers.
- Attachment chips: corner radius 10, padding 8/6, smaller `×` button on the right.
- Identifiers added: `message-input` on the `TextField`, `send-btn` on the send button (these exist in `OrbInputBar` today; they need to be added here since `OrbInputBar` is no longer the active input bar).

### EmptyStateView Refresh

- Single large orb at centre (size 96), in `idle` mood.
- Heading: `"О чём поговорим?"`, 22pt light, white 0.85.
- Three suggestion pills below in a horizontal scroll. Pills are hairline borders (`Theme.accent.opacity(0.3)`, 0.5pt) with text 13pt, no fill.
- Bottom row: two larger CTAs `"🎙️ Голосом"` and `"⌨ Текстом"` styled as hairline pills, taller (44pt).
- Identifier `empty-start-text` preserved on the text CTA.

### DateSeparator

Replace capsule with text-on-hairline:

```
─────────── СЕГОДНЯ ───────────
```

- Hairlines: 1pt high (0.5pt visible), `Theme.accent.opacity(0.1)`, flexible width.
- Text: SF Mono 10pt uppercase, tracking 1pt, `Theme.accent.opacity(0.4)`.
- Vertical padding 8pt.

### StatusBanner

Inline tweaks only:

- Corner radius 10 → 8.
- Icon 11pt → 10pt.
- Text 12pt unchanged.
- Max-width 280pt (clamped, not full-width).
- Padding tightened to 10/8.

### ActionBubble

Remove surrounding bubble. Keep `FlowLayout` of buttons. Answered state: capsule pill with `Theme.accent.opacity(0.12)` background + slim checkmark (using `CheckmarkShape`, not SF Symbol) on the left.

### OrbHomeView Addition

Add a "Continue" pill below the central orb when `store.conversations.count > 0`:

```
[Продолжить: Конфликты зависимостей →]
```

Tap = `coordinator.handleAction(.open(lastConv))` then navigate to ChatView. Visual: hairline pill, 13pt, `Theme.accent`. Hidden when there are no conversations.

### Theme Tokens

Add:

```swift
static let rowPadV: CGFloat = 12
static let rowPadH: CGFloat = 18
static let metaFont = Font.system(size: 10, design: .monospaced)
static let avatarDotSize: CGFloat = 8
static let hairlineColor = Theme.accent.opacity(0.05)
static let drawerWidth: CGFloat = UIScreen.main.bounds.width * 0.78
static let inputBarRadius: CGFloat = 22
```

Remove (or alias for backward compatibility if any non-chat call site still references them):

```swift
static let userBubble, assistantBubble
static let userBubbleBorder, assistantBubbleBorder
static let bubbleRadius
```

Retain `messagePadH` / `messagePadV` — still used by file / action / status inline cards.

## Data Flow

User sends a message:

```
ChatView.sendCurrent
  → coordinator.sendMessage
    → ws.send(text:...)
        sets lastUserSentAt = now
        sets isTyping = true (local optimistic)
        appends user ChatMessage with deliveryStatus = .sending
        sends WS frame
        on send callback: deliveryStatus = .sent (or .failed)
```

isBusy state becomes true (via `isTyping || lastUserSentAt within 5min && no later lastAssistantAt`). `ChatView` observes `ws.isBusy`, renders `ThinkingRow`.

Server-side typing event (`typing_start` / `typing_stop`) toggles `isTyping`. Status messages with `kind=system` update `thinkingDetail`.

Assistant message arrives:

```
handleIncoming(type: "message", role: "assistant")
  → appends ChatMessage
  → sets lastAssistantAt = now
  → isBusy now false (lastAssistantAt >= lastUserSentAt)
  → ThinkingRow removed via opacity transition
```

Heartbeat:

```
Every 25s:
  if (now - lastPongAt) > 35s → forceReconnect
  else ws.sendPing → on success: lastPongAt = now; on error: forceReconnect
```

App returns to foreground:

```
ScenePhase.active
  → if !isConnected: doConnect immediately
  → else: tickHeartbeat (faster dead-socket detection)
```

NWPathMonitor reports `.satisfied`:

```
ConnectivityMonitor.onSatisfied fires
  → if !isConnected: doConnect immediately
```

Drawer open:

```
ChatView.edgeSwipe or hamburger tap
  → drawerOpen = true, ZStack overlay slides in
Row tap in drawer
  → coordinator.handleAction(.open(conv))
      sets store.activeConversationId
      sets ws.conversationId = conv.id
      calls ws.loadMessages(from: store)
  → drawerOpen = false
ChatView re-renders with new messages
```

## Error Handling

- `ws.sendPing` error → `forceReconnect("ping failed")`.
- Pong stale > 35s → `forceReconnect("pong timeout")`.
- `doConnect` failure (URL parse, send) → existing flow: exponential backoff, capped at 30s.
- `isBusy` 5-min timeout → indicator clears even if server never sends `typing_stop` and never sends an assistant message.
- Delivery `.failed` → keeps the red icon visible; user sees the message is dead.
- Drawer drag offset clamped to `[-drawerWidth, drawerWidth]` so drag-out-of-bounds doesn't move content offscreen.
- Empty conversation list → drawer renders the "Новый чат" button + empty-state placeholder ("Нет диалогов").

## Testing

### Existing Tests — Updates Required

| File | Update |
|------|--------|
| `Sources/JarvisUITests/JarvisUITests.swift:85,106,130` | Predicates `bubble-user-*` / `bubble-assistant-*` → `row-user-*` / `row-assistant-*`. |
| `Sources/JarvisUITests/JarvisUITests.swift:38` | Keep `chat-view` as is. |
| `src/channels/ios-app.ws.test.ts` | Run unchanged — no protocol changes. Verify green. |
| `src/channels/ios-app.context.test.ts` | Run unchanged. |
| `src/channels/ios-read-receipts.test.ts` | Run unchanged. |

### New Unit Tests (XCTest)

**`WebSocketClientBusyTests.swift`** — `isBusy` truth table:

- `isTyping = true` → `isBusy == true`.
- `lastUserSentAt = .now, lastAssistantAt = nil` → `isBusy == true`.
- `lastUserSentAt = .now, lastAssistantAt = .now + 1s` → `isBusy == false`.
- `lastUserSentAt = .now - 400s, lastAssistantAt = nil` → `isBusy == false` (5-min timeout).
- After `disconnect()`: all flags reset → `isBusy == false`.

**`DeliveryChecksTests.swift`** — visual:

- Each `DeliveryStatus` renders the expected view type (Shape vs Image). Use SwiftUI ViewInspector or snapshot comparison.
- State change `sent → delivered` triggers animation (assertable via `withAnimation` block state).

**`HeartbeatTests.swift`** — timer behaviour (use a fake clock injection):

- `lastPongAt` older than `pongTimeout` → `forceReconnect` invoked.
- Successful ping callback updates `lastPongAt`.
- Failed ping callback invokes `forceReconnect`.

### New UI Tests (XCUITest)

**`DrawerTests.swift`** — drawer behaviour:

- Hamburger tap → element with `identifier == 'conv-drawer'` exists.
- Edge-swipe from `x = 0` to `x = 200` → drawer visible.
- Tap on `conv-row-<id>` → drawer dismissed, `chat-view` shows the messages of the tapped conversation (verify text of a known seeded message).
- Tap on shroud → drawer dismissed.
- Swipe drawer leftwards → drawer dismissed.

**`ThinkingRowTests.swift`** — busy state:

- Send a message in the UI test harness; before the seeded assistant reply, `thinking-row` exists.
- After the assistant reply, `thinking-row` disappears.

### New Identifiers

| Identifier | View |
|------------|------|
| `row-user-<id>` | MessageRow (user) |
| `row-assistant-<id>` | MessageRow (assistant) |
| `hamburger-btn` | Header hamburger button |
| `conv-drawer` | Drawer container |
| `conv-row-<conversationId>` | Each row in drawer |
| `thinking-row` | ThinkingRow when visible |
| `message-input` | UnifiedInputBar text field |
| `send-btn` | UnifiedInputBar send button |

### Run Commands

```bash
pnpm test                                                                # host vitest
xcodebuild test \
  -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:JarvisAppTests \
  -only-testing:JarvisUITests
```

### Visual Verification (Not Automated)

- Hairline thickness in light/dark conditions (only dark is supported, but verify gradient against `Theme.background`).
- Drawer animation timing on real device.
- Orb mood transitions, particularly `error` twitch.
- DeliveryChecks animation from `sent` → `delivered`.

## Open Questions

None — all design decisions resolved during brainstorming.

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Edge-swipe conflicts with iOS back-swipe gesture | ChatView is the root (no nav stack ancestor on this path); confirm by manual test in simulator. If it conflicts, switch to a slightly higher `minimumDistance` (12pt) on the back-gesture-coexistence requirement. |
| `URLSessionWebSocketTask.sendPing` not delivered through host's `ws` library | Verified at protocol level — Node's `ws` answers automatically. Add an integration test on `src/channels/ios-app.ts` to confirm ping/pong round-trip if not already present. |
| `isBusy` flickering on rapid round-trips | The 5-minute timeout and the `lastAssistantAt >= lastUserSentAt` check prevent flicker; verify by sending bursts of short messages. |
| Theme token removal breaks unrelated call sites | Run `grep -rn "Theme.userBubble\|Theme.assistantBubble\|Theme.bubbleRadius"` after edits; alias whatever survives. |
| Drawer drag-gesture starvation on tall messages | The edge-swipe is bounded to `startLocation.x < 24` — won't fire mid-content. Vertical scroll in body retains priority. |
| `MiniOrbView` size-conditional particle overlay regresses tiny orbs | Particle overlay is gated by `size >= 20`; the 14pt `ThinkingRow` orb keeps the simple pulse. Verify visually at all sizes (14, 22, 28, 36, 84). |

## Rollout

Single PR, single commit (or small commit series within one PR). No feature flag — the redesign is visual and atomic.

Manual smoke test before merge:

1. Cold launch → splash → orb home.
2. Tap home orb → ChatView shows last conversation.
3. Send a message → user row appears, checkmark animates `sending` → `sent` → `delivered`.
4. Long-press a message → context menu shows.
5. Edge-swipe right → drawer opens.
6. Tap another conversation → drawer closes, chat shows new messages.
7. Tap hamburger → drawer opens.
8. Disable network → ConnectionBanner appears within 35s, reconnects when network returns.
9. Background app for 60s → foreground → connection alive or reconnected quickly.
10. Long-running agent task (>1 min) → ThinkingRow stays visible until reply.

## References

- Existing chat view: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`
- Existing message renderer: `ios/JarvisApp/Sources/JarvisApp/Components/MessageBubble.swift`
- iOS app CLAUDE.md: `ios/JarvisApp/CLAUDE.md`
- Architecture overview (NanoClaw host side): `CLAUDE.md`
- Visual mockup (hybrid A): `.superpowers/brainstorm/89080-1779852823/content/hybrid.html`
- Drawer placement mockup: `.superpowers/brainstorm/89080-1779852823/content/list-placement.html`
