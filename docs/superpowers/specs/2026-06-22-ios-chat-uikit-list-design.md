# iOS chat list rendering rewrite (UIKit-backed) — design

**Date:** 2026-06-22
**Scope:** iOS app `ios/JarvisApp/` — the chat message **list container** only (Part A). Inline actions (Part B) are a separate spec.
**Status:** Design approved, pending implementation plan

## Problem

Switching between agents intermittently leaves the chat **blank until you manually scroll**, shows a **visible scroll animation** on switch, and **doesn't always land on the newest message**. Root cause (confirmed via on-device debugger: app fully idle, CPU 0% during the blank — not a CPU/data problem): SwiftUI `ScrollView` + `LazyVStack` + `.defaultScrollAnchor(.bottom)` cannot reliably bottom-pin when rows are tall/variable (e.g. big tables). `proxy.scrollTo(last, .bottom)` to a not-yet-realized giant row lands in empty space; the ScrollView also inherits the previous agent's scroll offset across the content swap. Successive patches (sleep-timed `scrollTo`, `BottomSizeChangesAnchor`, per-agent `.id` rebuild) each only relocated the symptom.

The fix is to stop fighting the SwiftUI scroll primitives and own the scroll with UIKit, which gives precise, reliable `contentOffset` control.

## Goal — behavior contract

1. **Open / agent switch:** instantly shows the newest message, pinned to the bottom — **no visible scroll animation, never blank, never requires a manual scroll**.
2. **New message while at bottom:** the list follows to it (subtle animation). **While scrolled up:** stays put and the scroll-to-bottom FAB appears.
3. **Keyboard open/close:** the list stays pinned to the bottom; no black gap.
4. **Scroll-to-bottom FAB:** appears only when actually scrolled up (precise, not the old always-on threshold).

## Decisions (locked)

- **Container:** `UICollectionView` (list layout) + `UICollectionViewDiffableDataSource`, wrapped in a `UIViewRepresentable`. Cells host the **existing** SwiftUI `MessageRow` / `DateSeparator` / `ThinkingRow` via `UIHostingConfiguration` — row rendering (markdown, images, audio, actions) is reused unchanged.
- **Non-inverted** list with reliable `scrollToItem(.bottom, animated:)`. No paging (the per-agent window caps at 500), so an inverted list's main payoff is absent. Inversion is a documented fallback only if a keyboard edge case forces it.
- Everything *around* the list stays SwiftUI: header, `UnifiedInputBar`, drawers, `EmptyStateView`, `ConnectionBanner`, the full-screen covers, the Payne workout button (removed in Part B), the FAB overlay.

## Architecture

### New files
- `Components/MessageListView.swift` — `UIViewRepresentable` + its `Coordinator`.
- `Models/ChatListItem.swift` — the diffable item model + the pure builder.

### `ChatListItem`
```
enum ChatListItem: Hashable {
    case date(Date)        // a day-separator row
    case message(String)   // a message, keyed by ChatMessage.id
    case thinking          // the "обдумываю" row
}
```
Hashable identity only (the data source is keyed by item identity). The cell provider looks the actual `ChatMessage` up from an index passed alongside (see data flow). `date` carries the day's start `Date` so identical days dedupe.

### Pure builder (testable)
```
func buildChatItems(_ messages: [ChatMessage], isBusy: Bool) -> [ChatListItem]
```
Walks `messages` oldest→newest, inserting a `.date(dayStart)` before the first message of each new calendar day (reusing the existing day-boundary rule from `shouldShowDateSeparator`), emitting `.message(id)` per message, and appending `.thinking` when `isBusy`. This is the single source of truth for separators + the thinking row; it has no UIKit dependency and is unit-tested.

### `MessageListView: UIViewRepresentable`
Inputs (SwiftUI → UIKit):
- `messages: [ChatMessage]` (the active agent's visible messages — already filtered upstream)
- `agentId: String` (the active agent; a change means "switch")
- `isBusy: Bool`
- callbacks (passed straight into the hosted `MessageRow`): `onImageTap: (UIImage, String?) -> Void`, `onFeedback: (String, Bool) -> Void`, `onActionTap: (String, String, String) -> Void`, `onRetry: (String) -> Void`, `onMessageRead: (String) -> Void`, `audioPlayer: AudioPlaybackService?`
- `@Binding var isScrolledUp: Bool` (UIKit → SwiftUI, drives the FAB)
- `scrollToBottomToken: Int` (a counter the FAB increments to request an animated jump)

`makeUIView`: builds the `UICollectionView` (`.list` config, no separators, clear background, `keyboardDismissMode = .none`), the diffable data source with a single cell registration whose `UIHostingConfiguration` switches on the item kind, sets `delegate` to the coordinator.

`updateUIView`: stores the latest `messages` (so the cell provider can resolve `.message(id)`), then:
- If `agentId` changed since last update → apply the new snapshot with `animatingDifferences: false`, then on the next runloop tick `scrollToBottom(animated: false)` (after layout, so item frames exist). **Instant, no visible scroll.**
- Else → apply with `animatingDifferences: true`; if `coordinator.wasAtBottom` (captured before apply) → `scrollToBottom(animated: true)`.
- If `scrollToBottomToken` changed → `scrollToBottom(animated: true)`.

### `Coordinator`
- Holds the data source + a weak collection-view ref + the latest `messages` map (`[String: ChatMessage]` by id) for the cell provider.
- `scrollViewDidScroll` → recompute `isNearBottom` and push `isScrolledUp` to the binding (debounced to avoid churn). `isNearBottom(offsetY, contentHeight, boundsHeight, inset, threshold)` is a **pure function** (unit-tested).
- `scrollToBottom(animated:)` → `scrollToItem(last, at: .bottom, animated:)` (or set contentOffset to max). Guards empty.
- Cell `willDisplay` for an assistant message → `onMessageRead(id)`.
- Keyboard observers (`keyboardWillShowNotification`/`Hide`) → if at bottom, re-pin (`scrollToBottom(animated: false)`).

## Data flow

`ChatView` keeps computing the active agent's `visibleMessages` (the per-agent filter, already in place). It passes `visibleMessages`, `active.active.rawValue`, and `ws.isBusy(agentId:)` into `MessageListView`. `MessageListView` builds `[ChatListItem]` via `buildChatItems` and applies the snapshot. The `else` branch of `ChatView`'s body (currently the `GeometryReader { ScrollViewReader { ScrollView … } }` + FAB) is replaced by `MessageListView(...)` + the FAB overlay; the `EmptyStateView` branch is unchanged.

## Removed

`ScrollView`, `LazyVStack`, `.defaultScrollAnchor(.bottom)`, `BottomSizeChangesAnchor`, `ScrolledUpDetector`, `ChatScrollOffsetKey`, `repinOnKeyboardChange`, the `renderedAgent` `.id` rebuild, and the competing scroll handlers (`onChange(messages.count)` scroll, `onChange(visibleMessages.last?.id)`, `onChange(isBusy)` thinking-scroll, `onChange(active.active)` sleep-Task, the keyboard `onReceive`s, the `onAppear` initial scroll). The `scrollToBottomAction`/`scrollToBottomFAB` plumbing is replaced by the `scrollToBottomToken` + the SwiftUI FAB overlay reading `isScrolledUp`.

## Error handling / edge cases

- **Empty agent:** `messages` empty → `ChatView` shows `EmptyStateView` (unchanged branch), `MessageListView` not mounted.
- **Cell reuse + SwiftUI `@State`:** the hosting cell is re-configured per item id on reuse; `MessageRow`'s local `@State` (feedback) resets on reuse, matching today's behavior.
- **Very tall single row (giant table):** self-sizing `UIHostingConfiguration` measures it; `scrollToItem(.bottom)` reliably reaches its bottom (UIKit, unlike SwiftUI).
- **Rapid agent cycling:** each `updateUIView` is idempotent; the agent-change branch always ends bottom-pinned.

## Testing

**Unit (pure, no UIKit):**
- `buildChatItems`: date separator inserted at each day boundary and only there; `.thinking` appended iff `isBusy`; message order preserved; ids unique.
- `isNearBottom`: true at/near bottom (within threshold), false when scrolled up, correct with content shorter than viewport.

**Manual device matrix (the behavior contract):**
- Cycle through all agents in order repeatedly → each lands instantly on the newest message, no blank, no visible scroll.
- New inbound message while at bottom (follows) and while scrolled up (stays + FAB).
- Keyboard open/close in an image-heavy chat → no black gap, stays pinned.
- Tap image / 👍👎 / retry / audio still work from hosted cells.

## Affected files

| File | Change |
|------|--------|
| `Components/MessageListView.swift` | **New** — UIViewRepresentable + Coordinator + diffable data source + hosting cell. |
| `Models/ChatListItem.swift` | **New** — item enum + `buildChatItems` + `isNearBottom`. |
| `Views/ChatView.swift` | Replace the `else`-branch ScrollView block with `MessageListView` + FAB overlay; delete the removed scroll machinery; keep chrome, empty state, covers, per-agent `visibleMessages`, `activeBusy`. |
| `Components/MessageRow.swift` | Unchanged (hosted as-is). Possibly expose nothing new. |

Version bump (`CURRENT_PROJECT_VERSION` + `xcodegen generate`) per the repo's iOS rule when the change lands.

## Non-goals

- Inline actions / workout-start-as-inline / removing Payne's global button → **Part B**, separate spec.
- Message paging / load-older-on-scroll-up → not needed (500/agent cap).
- Inverted list → fallback only.
