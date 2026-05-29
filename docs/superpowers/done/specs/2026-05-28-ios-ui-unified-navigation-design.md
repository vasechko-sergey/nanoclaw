# iOS — Unified Navigation, Voice Mode, Watch Companion, Satellite Continuations

**Date:** 2026-05-28
**Scope:** iOS app (`ios/JarvisApp/`) + minimal server-side touches for watch APNs token

## Problem

Current top-level navigation mixes two languages:

- **Drawers slide from the side** (left drawer = conversations, edge-swipe + tap on top-left).
- **Profile and Settings appear as bottom sheets** (`.sheet(isPresented:)`), with the "Профиль/Настройки" buttons living at the bottom of the left drawer or as standalone toolbar buttons.

The mix breaks the visual rhythm. On the home screen the top-left is a bare status dot opening a bottom sheet; in chat the same position is a `MiniOrbView` opening the left drawer. Two orbs render on the same chat screen (header + input bar). Settings/Profile sheets jar against the side-drawer language already established.

Beyond cleanup, three new affordances were requested:

1. **Voice-fullscreen ("Glass") mode** — a chat-less voice loop driven by the orb, modelled after Iron Man's HUD.
2. **Apple Watch companion** — read incoming messages, dictate replies via the same WebSocket.
3. **Conversation-as-satellite** — let pinned/active conversations appear as satellites in the home orb cluster.

## Goals

- Unify all top-level navigation under **side drawers** (left = conversations, right = profile + context + settings).
- Replace top-left and top-right header buttons with **mirrored status dots**. One orb per screen.
- Add a **voice-fullscreen mode** that uses the existing `WebSocketClient`, `SpeechManager`, `SpeechSynthesizer` — no new transport.
- Add a **watchOS target** that shares core code via an in-package SPM target.
- Extend `OrbHomeView` orbit cluster with **conversation satellites** for pinned/recent chats.

## Non-Goals

- Live-context chip in the header (deferred).
- Force-touch radial menu on header dot (deferred).
- Drawer "Память" section (deferred — covered separately under proactive spec).
- Dynamic Island / Lock-screen widget (deferred).
- Standalone Apple Watch (without iPhone companion) — deferred.
- Watch-side image/video viewing (text-only in v1).

## Architecture

### Navigation Model

```
┌──────────────────────────────────────┐
│ [● dot-L]   J A R V I S    [● dot-R] │  ← unified header
├──────────────────────────────────────┤
│                                      │
│           (screen body)              │
│                                      │
└──────────────────────────────────────┘

dot-L (status: online/offline) → left drawer  = conversations
dot-R (phase: idle/processing) → right drawer = profile + context + settings
```

Edge-swipe gestures from left and right both open their respective drawers. Swiping outward closes. Drawer width: `Theme.drawerWidth` (78% of screen).

Header components:

| Position | Now | After |
|---|---|---|
| ChatView TL | `MiniOrbView` + status dot, opens left drawer | **Status dot only**, opens left drawer |
| ChatView TR | `gearshape`, opens Settings sheet | **Phase dot**, opens right drawer |
| OrbHomeView TL | Tiny status circle, opens Profile sheet | **Status dot only**, opens left drawer |
| OrbHomeView TR | `gearshape`, opens Settings sheet | **Phase dot**, opens right drawer |

The chat header's `MiniOrbView` is removed. One orb per screen — input-bar `MiniOrbView` remains, the home center `OrbView` remains.

### Status Dot Component

New `HeaderStatusDot` view, replaces both the chat header's MiniOrb+dot stack and the home header's status circle:

```swift
struct HeaderStatusDot: View {
    enum Side { case left, right }
    let side: Side
    let isConnected: Bool        // left side only
    let phase: OrbMood           // right side only
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(strokeColor.opacity(0.2), lineWidth: Theme.lineAccent)
                    .frame(width: Theme.scaled(22), height: Theme.scaled(22))
                Circle()
                    .fill(fillColor)
                    .frame(width: Theme.scaled(8), height: Theme.scaled(8))
                    .shadow(color: fillColor.opacity(0.8), radius: 4)
            }
            .frame(width: Theme.minTapSize, height: Theme.minTapSize)
        }
    }

    private var fillColor: Color {
        switch side {
        case .left:  return isConnected ? Theme.online : Theme.offline
        case .right:
            switch phase {
            case .processing, .listening: return Theme.accent
            case .speaking:               return Theme.accent
            case .error:                  return Theme.offline
            default:                      return Theme.accentMedium
            }
        }
    }
    private var strokeColor: Color { fillColor }
}
```

### Right Drawer — `RightDrawerContent`

Single scroll, three sections, no tabs. Mirrors the structure of `DrawerContent` (left drawer) for visual symmetry.

```
┌─ RightDrawerContent ────────────────┐
│ [Аватар] Имя                        │  Profile card (always at top)
│ ● online · WS · APNs OK   [Reconnect]│
├─────────────────────────────────────┤
│ ПРОФИЛЬ                              │
│   platform id           [copy]       │
│   feedback summary                   │
├─────────────────────────────────────┤
│ КОНТЕКСТ                             │
│   📍 Canggu                  [●]     │  toggle useLocation
│   🏃 6 230 · ❤️ 68 bpm        [●]     │  toggle useHealth
│   📅 Стэндап 14:00           [●]     │  toggle useCalendar
│   ⚡ 82% · 📶 wifi · 🌐 Asia/...      │  read-only
│   [Запросить контекст сейчас]        │
├─────────────────────────────────────┤
│ НАСТРОЙКИ                            │
│   serverURL                          │
│   bearerToken                        │
│   голос TTS                          │
│   enterToSend                        │
│   statusEmoji                        │
│   ── Voice mode ──                   │
│   auto-resume listening      [●]     │
│   push-to-talk               [○]     │
│   silence timeout    [15][30][60]    │
│   ── Watch ──                        │
│   Apple Watch companion      [○]     │
├─────────────────────────────────────┤
│ [Logout] [Reset all]                 │
└──────────────────────────────────────┘
```

Built as one `ScrollView` + `LazyVStack` with section headers. Each section header re-uses the styling from the left drawer's `sectionHeader` helper.

Existing `SettingsView` is **embedded** into the НАСТРОЙКИ section rather than presented as a sheet. The form rows already exist there — extract them into a `SettingsFormBody` view that both `RightDrawerContent` (embed) and the first-run `SettingsView` flow (still a sheet during initial setup, since drawer isn't reachable until WS auth) re-use.

`ProfileView`'s body is similarly extracted into `ProfileFormBody`.

### Drawer Mounting & Gestures

`ChatView` and `OrbHomeView` both gain a right-side drawer alongside the existing left-side one:

```swift
ZStack {
    // ... existing content + left drawer ...

    // Right drawer
    if rightDrawerOpen { shroud overlay }
    RightDrawerContent(...)
        .frame(width: Theme.drawerWidth)
        .offset(x: rightDrawerOpen
                   ? UIScreen.main.bounds.width - Theme.drawerWidth + rightDrawerDragOffset
                   : UIScreen.main.bounds.width + max(0, min(-rightDrawerDragOffset, Theme.drawerWidth)))
        .gesture(rightDrawerDragToClose)
}
.simultaneousGesture(rightEdgeSwipeGesture)
```

Mirror of left drawer logic. Edge-swipe trigger zone: rightmost 24pt of screen width.

**Collision rule:** when one drawer is open, the opposite-edge swipe is ignored. Both cannot be open at once (`drawerOpen && rightDrawerOpen` invariant violated — guard in state setters).

### Voice-Fullscreen Mode (`OrbVoiceView`)

New view, presented `.fullScreenCover` over either `OrbHomeView` or `ChatView`. Shares `WebSocketClient`, `SpeechManager`, `SpeechSynthesizer` via `AppCoordinator`.

**Entry points:**

| Where | Gesture | Action |
|---|---|---|
| OrbHomeView center orb | Tap (already wired to `onStartVoiceChat`) | Open `OrbVoiceView` instead of `ChatView` |
| ChatView | Pinch-out on MiniOrb in input bar | Open `OrbVoiceView` |
| Either screen | Long-press top-left dot | Open `OrbVoiceView` (replaces deferred "status report" idea) |

**Screen layout:**

```
┌─────────────────────────────────────┐
│  ● online                  14:32    │  thin status bar
│                                     │
│                                     │
│            ╭───────╮                │
│           │  ORB    │  large OrbView (size = min(screenW * 0.6, 280))
│            ╰───────╯                │  mood-driven
│                                     │
│       «привет, что нового…»         │  live partial transcript
│                                     │  monospaced, fade in/out
│                                     │
│                                     │
│     [ к чату ↑ ]      [ × ]         │  bottom controls
└─────────────────────────────────────┘
```

**Loop:**

1. On open: orb `.listening`, `SpeechManager.start()`.
2. Partial transcript updates → render under orb.
3. On final result OR user-tap-orb-to-send: `SpeechManager.stop()`, `WebSocketClient.send(text:)`. Orb → `.processing`.
4. Assistant message arrives → orb `.speaking`, `SpeechSynthesizer.speak(text)`.
5. `synthesizer.delegate didFinish` → if `autoResumeListening` on, orb → `.listening`, `SpeechManager.start()`; else orb → `.calm`, wait for tap.
6. Silence > `silenceTimeout` while listening with no partial → orb `.calm`, stop recording. Tap orb to resume.
7. Tap "к чату" → dismiss to `ChatView` with the **same conversationId** — history preserved.
8. Tap × → dismiss to previous screen, stop both STT and TTS.

**Push-to-talk mode (opt-in):**
Orb is held → recording. Released → send. Same `SpeechManager` API, but `start()`/`stop()` driven by gesture `onChanged`/`onEnded` instead of auto-loop.

**Settings keys (new in `AppSettings`):**
- `autoResumeListening: Bool = true`
- `pushToTalk: Bool = false`
- `silenceTimeoutSec: Int = 30`   (allowed: 15, 30, 60)

**No new server protocol.** Same `message` payload, optional `viaVoice: true` flag added to context for telemetry / future personality tuning (e.g., agent might respond more concisely when input came via voice).

### Apple Watch Companion

New target `JarvisWatch` (watchOS app) in `project.yml`. Min watchOS 10. Bundle ID `com.vasechko.jarvis.watch`.

**Shared code:**

Extract a new in-repo SPM library target `JarvisCore` containing:

- `Models/Message.swift` (ChatMessage, DeliveryStatus, FileInfo)
- `Models/AppSettings.swift`
- `Services/WebSocketClient.swift`
- `Services/MessageCache.swift`
- `Utility/Theme.swift` (split: `JarvisCore` exports color/font primitives; `JarvisApp` adds iOS-only haptics/screen-scale; `JarvisWatch` overrides for watch-screen scale)

iOS app + watch app both depend on `JarvisCore`. `project.yml` adds:

```yaml
packages:
  JarvisCore:
    path: ./Sources/JarvisCore

targets:
  JarvisApp:
    dependencies:
      - package: JarvisCore
  JarvisWatch:
    type: application
    platform: watchOS
    deploymentTarget: "10.0"
    sources: [Sources/JarvisWatch]
    dependencies:
      - package: JarvisCore
```

**Watch UI:**

```
┌───────────────┐
│   ╭───╮       │
│  │ orb │  ●   │  small orb + connection dot
│   ╰───╯       │
├───────────────┤
│ Last assistant│  message text, monospaced
│ message text  │  scroll via crown
│ ...           │
├───────────────┤
│  [🎤 hold]    │  push-to-talk button (full-width)
└───────────────┘
```

- **Tap orb** or hold mic button → record via watch `SFSpeechRecognizer` (force `ru-RU`, same as iOS).
- Release → `WebSocketClient.send()`. WS connection runs **on iPhone via watch-companion mode**: watch sends `WCSession` request to iPhone, iPhone forwards to WS. Standalone WS from watch is out of scope v1.
- Incoming messages arrive on iPhone, are forwarded via `WCSession.transferUserInfo` to watch.
- APNs notifications already mirror from iPhone to watch automatically — no separate push setup.

**Watch ↔ iPhone link:**

```swift
// iOS side: AppCoordinator publishes incoming assistant messages → WCSession
WCSession.default.transferUserInfo([
    "type": "message",
    "text": msg.text,
    "id": msg.id,
    "ts": ISO8601DateFormatter().string(from: msg.timestamp),
])

// Watch side: WCSessionDelegate receives, appends to local @State list
func session(_ s: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    DispatchQueue.main.async { self.messages.append(.from(userInfo)) }
}

// Watch → iOS: dictated text round-trip
WCSession.default.sendMessage([
    "type": "send_text",
    "text": dictated,
], replyHandler: nil)
```

**Settings toggle:** `Apple Watch companion [on/off]` in right drawer. When off, iOS side stops `WCSession.transferUserInfo` calls; watch app shows "disabled" state.

**Out of scope v1:**
- Attachments (images, files) on watch
- Drawer / conversation list on watch
- Standalone WS (no-iPhone-needed mode)
- Voice-fullscreen on watch (small screen is already voice-first)

### Conversation-as-Satellite (Home)

`OrbHomeView.defaultSatellites` is extended to include conversation-shortcut satellites:

**Rules:**

1. **Active satellite:** if `coordinator.store.activeConversationId != nil` AND `ws.messages.last?.role == .assistant` AND `last message timestamp` within last 24h.
   - Icon: `bubble.left.fill`
   - Label: truncated conversation title (max 14 chars)
   - Tap → `onContinueChat()`
2. **Pinned satellites:** up to **2** pinned conversations from `store.conversations.filter { $0.isPinned }`, sorted by `lastMessageAt` descending.
   - Icon: `pin.fill`
   - Label: truncated title
   - Tap → `onAction(.open(conv))` then `onContinueChat()`
3. Total conversation satellites capped at 3. Suggestions still occupy 4 slots. Total `defaultSatellites` count: up to 4 (suggestions) + 3 (conversations) = 7.
4. When `defaultSatellites.count > 6`, radius bumps from `Theme.scaled(130)` to `Theme.scaled(150)` to prevent overlap.

**Implementation:**

```swift
private var conversationSatellites: [(icon: String, label: String, isChat: Bool, action: () -> Void)] {
    var items: [(String, String, Bool, () -> Void)] = []

    // Active
    if hasActiveChat,
       let last = coordinator.ws.messages.last,
       last.role == .assistant,
       Date().timeIntervalSince(last.timestamp) < 86400 {
        let title = coordinator.store.activeConversation?.title ?? "Диалог"
        items.append(("bubble.left.fill", truncate(title, 14), true, { onContinueChat() }))
    }

    // Pinned (up to 2, dedupe with active)
    let activeId = coordinator.store.activeConversationId
    let pinned = coordinator.store.conversations
        .filter { $0.isPinned && $0.id != activeId }
        .sorted { $0.lastMessageAt > $1.lastMessageAt }
        .prefix(2)
    for conv in pinned {
        items.append(("pin.fill", truncate(conv.title, 14), false, {
            coordinator.handleAction(.open(conv))
            onContinueChat()
        }))
    }

    return items
}

private var defaultSatellites: [...] {
    let suggestions = contextualSuggestions.map { ... }
    return suggestions + conversationSatellites
}
```

Existing `hasActiveChat → "Диалог"` button at the end of `defaultSatellites` is removed (replaced by the active-satellite above).

### Cleanup Summary

| File | Change |
|---|---|
| `Views/ChatView.swift` | Remove MiniOrb + gearshape from header. Replace with `HeaderStatusDot(.left)` and `HeaderStatusDot(.right)`. Remove `showSettings` / `showProfile` state + their `.sheet` modifiers. Add `rightDrawerOpen` state + drawer mount. Add pinch-out gesture on input-bar MiniOrb → voice mode. |
| `Views/OrbHomeView.swift` | Remove status circle + gearshape from header. Replace with two `HeaderStatusDot`. Add `leftDrawerOpen` / `rightDrawerOpen` state + drawer mounts. Add conversation satellites to `defaultSatellites`. Remove old `showProfile` sheet. Update `onShowSettings` callback removal — settings is now inside right drawer. |
| `Views/ContentView.swift` | Remove `showSettings` sheet path (was for first-run; first-run still uses fullScreenCover with `SettingsView(isInitialSetup: true)`, separate path). |
| `Views/ConversationListView.swift` `DrawerContent` | Remove bottom `Профиль/Настройки` button row. Left drawer = conversations only. |
| `Views/SettingsView.swift` | Extract row body into `SettingsFormBody` view, callable from both initial-setup sheet AND right drawer embed. |
| `Views/ProfileView.swift` | Extract row body into `ProfileFormBody`, same pattern. |
| `Components/HeaderStatusDot.swift` | **NEW** |
| `Views/RightDrawerContent.swift` | **NEW** |
| `Views/OrbVoiceView.swift` | **NEW** |
| `Models/AppSettings.swift` | Add `autoResumeListening`, `pushToTalk`, `silenceTimeoutSec`, `watchCompanionEnabled`. |
| `JarvisApp.swift` | Add `WCSessionDelegate` if `watchCompanionEnabled` — push iOS → watch. |
| `project.yml` | Add `JarvisWatch` target + `JarvisCore` SPM library + dependency wiring. |
| `Sources/JarvisCore/...` | **NEW** — extracted from `JarvisApp/Models/`, `Services/WebSocketClient.swift`, `MessageCache.swift`. |
| `Sources/JarvisWatch/JarvisWatchApp.swift` | **NEW** — `@main` watch app, ContentView with orb + last messages + dictation. |

## Data Flow

**Voice mode (steady-state listening):**

```
SpeechManager.onTranscript ──► OrbVoiceView.partialText (binding)
                                 │
                                 ▼ (on final)
                          WebSocketClient.send(text)
                                 │
                                 ▼
                          orb.mood = .processing
                                 │
                                 ▼ (assistant arrives)
                          orb.mood = .speaking
                          SpeechSynthesizer.speak(text)
                                 │
                                 ▼ (didFinish)
                          if autoResumeListening → SpeechManager.start()
                                                   orb.mood = .listening
```

**Watch dictation:**

```
Watch UI (mic held)
   │ WCSession.sendMessage({type: send_text, text})
   ▼
iOS AppCoordinator.handleWatchSendText(text)
   │ WebSocketClient.send(text)
   ▼
Server / agent
   │ assistant reply via WS
   ▼
iOS WebSocketClient.onMessageReceived
   │ WCSession.transferUserInfo({type, text, ...})
   ▼
Watch ContentView.messages.append(...)
```

## Error Handling

- **Voice mode, STT fails to start:** `SpeechManager.permissionDenied = true` → `OrbVoiceView` shows inline alert "Разрешите распознавание речи в настройках" + dismiss button.
- **WS disconnected during voice mode:** orb `.error`, top status dot turns red. Recording continues; sent message marks `.failed`. On reconnect, `WebSocketClient` re-flushes (existing behaviour).
- **TTS interrupted (call, alarm):** existing `handleInterruption` stops synthesizer. Orb → `.calm`, wait for user tap to resume listening.
- **Drawer collision** (both swipe at once): hard guard in setter — opening left forces right closed, and vice versa. Animation: 200ms close before open.
- **Watch WCSession unreachable:** silently skip transfer; on next iOS app foreground, re-emit last 10 messages via `transferUserInfo` to catch up watch.
- **Conversation satellite when conversation deleted while home is visible:** `OrbHomeView` observes `store.conversations` — re-computes `defaultSatellites` automatically (Observation triggers re-render).

## Testing

**Unit tests (`Tests/JarvisAppTests/`):**

| Test | Asserts |
|---|---|
| `HeaderStatusDotTests` | dot color matches `(side, isConnected/phase)` matrix |
| `RightDrawerContentTests` | renders three sections in order; toggles correctly persist to `AppSettings` |
| `OrbVoiceViewModelTests` | loop state machine: `idle → listening → processing → speaking → listening` with `autoResumeListening = true`; stops at `.calm` with off |
| `OrbVoiceSilenceTimeoutTests` | after `silenceTimeoutSec` without partial, transitions to `.calm` |
| `ConversationSatellitesTests` | active + pinned correctly ordered, capped at 3, dedup with active, radius bumps when count > 6 |
| `WatchBridgeTests` | iOS-side `transferUserInfo` payload contains required keys; on reply, watch-side decoder reconstructs `ChatMessage` |

**UI tests (`Tests/JarvisUITests/`):**

| Test | Steps |
|---|---|
| `RightDrawerOpenTest` | Edge-swipe from right → drawer visible; tap outside → closes; profile/context/settings sections present |
| `DrawerCollisionTest` | Open left drawer; edge-swipe from right is ignored until left closed |
| `VoiceModeEntryTest` | Tap home orb → `OrbVoiceView` appears; tap × → returns to home with no chat created |
| `VoiceModeChatHandoffTest` | Enter voice from chat with N messages; tap "к чату" → returns with N messages still visible |
| `SatelliteContinuationTest` | With one pinned + one active conversation, both appear in orb cluster; tapping each opens correct conv |

**Manual checks (Watch — no UI test infrastructure yet):**

- Send message from iPhone → arrives on watch.
- Hold watch mic, speak Russian phrase → text appears in iPhone chat with `viaVoice: true`.
- Toggle "Apple Watch companion" off → watch shows "disabled"; subsequent iPhone messages not transferred.

## Migration

No data migration. State changes:

- `AppSettings` gains four new keys with defaults — `@AppStorage` reads default for absent keys, safe.
- `SettingsView` is no longer presented as a sheet from ChatView/OrbHomeView, but the **first-run flow** (when `serverURL` empty) keeps the existing `fullScreenCover` path — unchanged.

Existing chat history, conversations, message cache: untouched.

## Open Questions

1. **Long-press top-left dot in voice mode** — does it close, or no-op? Proposal: close (matches X button).
2. **Multiple status emoji in right drawer** — keep current single emoji or allow set? Proposal: keep single, matches existing minimal API.
3. **Watch dictation language** — hardcode `ru-RU` matching iOS, or read from device locale? Proposal: hardcode for v1, matches iOS `SpeechManager`.

## Out of Scope (Deferred)

- Live-context chip in header
- Force-touch radial on header dot
- Drawer "Память" section
- Dynamic Island integration
- Lock-screen widget
- Standalone watch WS
- Watch attachments
- Face-down ambient

These are listed in `2026-05-28-ios-proactive-design.md` and `2026-05-28-ios-reliability-design.md` where relevant, or left for future specs.
