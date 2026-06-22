# iOS Chat List Rendering Rewrite (UIKit-backed) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fragile SwiftUI `ScrollView`+`LazyVStack` chat list with a UIKit `UICollectionView` (hosting the existing SwiftUI rows) so agent-switch lands instantly on the newest message — no blank, no visible scroll, always bottom-pinned — and keep one always-up WebSocket across agents.

**Architecture:** A new `MessageListView: UIViewRepresentable` wraps a `UICollectionView` (list layout) with a `UICollectionViewDiffableDataSource`; cells render the existing `MessageRow`/`DateSeparator`/`ThinkingRow` via `UIHostingConfiguration`. A pure `buildChatItems` produces the diffable item list (date separators + thinking row); a pure `isNearBottom` drives the FAB. `ChatView` swaps its ScrollView block for `MessageListView` + the SwiftUI FAB overlay, deletes the old scroll machinery, and stops disconnecting the socket on view lifecycle.

**Tech Stack:** Swift 5.9 / SwiftUI / UIKit (`UICollectionView`, diffable data source, `UIHostingConfiguration`), XCTest. Module name `Jarvis` (tests: `@testable import Jarvis`). XcodeGen project. Deployment iOS 18.

---

## Conventions (every task)

- Test files: `@testable import Jarvis` (NOT `JarvisApp`).
- After creating a new `.swift` file: `cd ios/JarvisApp && xcodegen generate` (from repo root: `cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw`).
- Simulator: **`name=iPhone 17`** (iPhone 16 not installed). First sim build is slow/cold.
- Run one test:
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:JarvisAppTests/<Class>/<method> 2>&1 | tail -30
```
- Build only:
```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -25
```

## File Structure

| File | Responsibility | New? |
|------|----------------|------|
| `ios/JarvisApp/Sources/JarvisApp/Models/ChatListItem.swift` | Diffable item enum + pure `buildChatItems` + pure `isNearBottom`. | **New** |
| `ios/JarvisApp/Sources/JarvisApp/Components/MessageListView.swift` | `UIViewRepresentable` + `Coordinator`: UICollectionView, diffable data source, hosting cell, scroll/keyboard control. | **New** |
| `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` | Swap ScrollView block → `MessageListView` + FAB; delete old scroll machinery; remove `onDisappear` disconnect. | Modify |
| `ios/JarvisApp/Sources/JarvisAppTests/ChatListItemTests.swift` | Tests for `buildChatItems` + `isNearBottom`. | **New** |
| `ios/JarvisApp/project.yml` | Version bump. | Modify |

---

## Task 1: `ChatListItem` model + pure builders

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Models/ChatListItem.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/ChatListItemTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/JarvisApp/Sources/JarvisAppTests/ChatListItemTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class ChatListItemTests: XCTestCase {

    private func msg(_ id: String, _ ts: Date) -> ChatMessage {
        ChatMessage.text(id, role: .user, text: id, timestamp: ts)
    }

    func test_buildChatItems_dateSeparatorsAndThinking() {
        let cal = Calendar.current
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)        // some day
        let day2 = day1.addingTimeInterval(26 * 3600)                // next calendar day
        let items = buildChatItems(
            [msg("a", day1), msg("b", day1.addingTimeInterval(60)), msg("c", day2)],
            isBusy: true
        )
        XCTAssertEqual(items, [
            .date(cal.startOfDay(for: day1)),
            .message("a"),
            .message("b"),
            .date(cal.startOfDay(for: day2)),
            .message("c"),
            .thinking,
        ])
    }

    func test_buildChatItems_singleMessage_noSeparator_noThinkingWhenIdle() {
        let items = buildChatItems([msg("a", Date(timeIntervalSince1970: 1_700_000_000))], isBusy: false)
        XCTAssertEqual(items, [.message("a")])  // count==1 → no leading separator (matches old rule)
    }

    func test_isNearBottom() {
        // pinned at bottom
        XCTAssertTrue(isNearBottom(offsetY: 900, contentHeight: 1000, boundsHeight: 100, bottomInset: 0, threshold: 160))
        // scrolled up beyond threshold
        XCTAssertFalse(isNearBottom(offsetY: 100, contentHeight: 1000, boundsHeight: 100, bottomInset: 0, threshold: 160))
        // content shorter than viewport → always "near bottom"
        XCTAssertTrue(isNearBottom(offsetY: 0, contentHeight: 50, boundsHeight: 100, bottomInset: 0, threshold: 160))
    }
}
```

- [ ] **Step 2: Run, verify FAIL**

```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:JarvisAppTests/ChatListItemTests 2>&1 | tail -30
```
Expected: FAIL — `cannot find 'buildChatItems' / 'isNearBottom' / 'ChatListItem' in scope`.

- [ ] **Step 3: Implement**

Create `ios/JarvisApp/Sources/JarvisApp/Models/ChatListItem.swift`:

```swift
import Foundation
import CoreGraphics

/// One row in the chat list. Identity-only (the diffable data source keys by
/// this); the actual `ChatMessage` is resolved by id at cell-config time.
enum ChatListItem: Hashable {
    case date(Date)        // day-separator (the day's startOfDay)
    case message(String)   // a message, by ChatMessage.id
    case thinking          // the "обдумываю" busy row
}

/// Build the diffable item list from the active agent's messages. Inserts a
/// day-separator using the SAME rule the old `ChatView.shouldShowDateSeparator`
/// used (leading separator only when there's more than one message; otherwise at
/// each calendar-day boundary), and appends `.thinking` when busy. Pure — no
/// UIKit — so it is unit-tested directly.
func buildChatItems(_ messages: [ChatMessage], isBusy: Bool) -> [ChatListItem] {
    let cal = Calendar.current
    var items: [ChatListItem] = []
    for (i, m) in messages.enumerated() {
        let showSeparator: Bool
        if i == 0 {
            showSeparator = messages.count > 1
        } else {
            showSeparator = !cal.isDate(m.timestamp, inSameDayAs: messages[i - 1].timestamp)
        }
        if showSeparator { items.append(.date(cal.startOfDay(for: m.timestamp))) }
        items.append(.message(m.id))
    }
    if isBusy { items.append(.thinking) }
    return items
}

/// Whether a scroll view is at/near its bottom. Pure so the FAB logic is tested
/// without UIKit. `threshold` is how far up (points) still counts as "at bottom".
func isNearBottom(offsetY: CGFloat, contentHeight: CGFloat, boundsHeight: CGFloat,
                  bottomInset: CGFloat, threshold: CGFloat) -> Bool {
    let maxOffset = max(0, contentHeight + bottomInset - boundsHeight)
    return offsetY >= maxOffset - threshold
}
```

- [ ] **Step 4: Run, verify PASS** (3 tests)

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:JarvisAppTests/ChatListItemTests 2>&1 | tail -30
```

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/ChatListItem.swift \
        ios/JarvisApp/Sources/JarvisAppTests/ChatListItemTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): ChatListItem model + pure buildChatItems/isNearBottom"
```

---

## Task 2: `MessageListView` (UICollectionView hosting SwiftUI cells)

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Components/MessageListView.swift`

No unit test (UIKit scroll behavior is manual-verified in Task 4; the pure logic it relies on is tested in Task 1). Verification here is a compile.

- [ ] **Step 0: Make `DateSeparator` reachable from this file**

`DateSeparator` is currently `private struct DateSeparator: View` at the bottom of `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`, so another file can't host it. Remove the `private`:

```swift
struct DateSeparator: View {
```

(`ThinkingRow` and `MessageRow` are already internal — no change.)

- [ ] **Step 1: Create the file**

Create `ios/JarvisApp/Sources/JarvisApp/Components/MessageListView.swift`:

```swift
import SwiftUI
import UIKit

/// UIKit-backed chat message list. A `UICollectionView` (list layout) with a
/// diffable data source whose cells host the existing SwiftUI `MessageRow` /
/// `DateSeparator` / `ThinkingRow` via `UIHostingConfiguration`. Replaces the
/// SwiftUI `ScrollView` + `LazyVStack`, which could not reliably bottom-pin tall
/// rows on agent switch (blank-until-scroll). UIKit gives precise `contentOffset`
/// control: switch = apply snapshot (no animation) + scroll to bottom instantly.
struct MessageListView: UIViewRepresentable {
    let messages: [ChatMessage]
    let agentId: String
    let isBusy: Bool
    var onImageTap: (UIImage, String?) -> Void
    var onFeedback: (String, Bool) -> Void
    var onActionTap: (String, String, String) -> Void
    var onRetry: (String) -> Void
    var onMessageRead: (String) -> Void
    var audioPlayer: AudioPlaybackService?
    @Binding var isScrolledUp: Bool
    /// Incremented by the FAB tap to request an animated jump to the bottom.
    var scrollToBottomToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.keyboardDismissMode = .none
        cv.alwaysBounceVertical = true
        cv.contentInsetAdjustmentBehavior = .always
        cv.delegate = context.coordinator
        context.coordinator.configureDataSource(cv)
        context.coordinator.observeKeyboard()
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        context.coordinator.update(parent: self, collectionView: cv)
    }

    static func dismantleUIView(_ cv: UICollectionView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, UICollectionViewDelegate {
        private var parent: MessageListView
        private var dataSource: UICollectionViewDiffableDataSource<Int, ChatListItem>!
        private weak var collectionView: UICollectionView?
        private var messagesById: [String: ChatMessage] = [:]
        private var lastAgentId: String?
        private var lastToken: Int = 0
        private var wasAtBottom = true

        init(_ parent: MessageListView) { self.parent = parent }

        func configureDataSource(_ cv: UICollectionView) {
            collectionView = cv
            let reg = UICollectionView.CellRegistration<UICollectionViewListCell, ChatListItem> { [weak self] cell, _, item in
                guard let self else { return }
                var bg = UIBackgroundConfiguration.listPlainCell()
                bg.backgroundColor = .clear
                cell.backgroundConfiguration = bg
                switch item {
                case .date(let day):
                    cell.contentConfiguration = UIHostingConfiguration { DateSeparator(date: day) }
                        .margins(.all, 0)
                case .thinking:
                    cell.contentConfiguration = UIHostingConfiguration { ThinkingRow(detail: nil) }
                        .margins(.all, 0)
                case .message(let id):
                    guard let msg = self.messagesById[id] else {
                        cell.contentConfiguration = nil
                        return
                    }
                    let isLast = (self.messagesById.count > 0) && (self.parent.messages.last?.id == id)
                    cell.contentConfiguration = UIHostingConfiguration {
                        MessageRow(
                            message: msg,
                            isLast: isLast,
                            onImageTap: self.parent.onImageTap,
                            onFeedback: self.parent.onFeedback,
                            onActionTap: self.parent.onActionTap,
                            onRetry: self.parent.onRetry,
                            audioPlayer: self.parent.audioPlayer
                        )
                    }
                    .margins(.all, 0)
                }
            }
            dataSource = UICollectionViewDiffableDataSource<Int, ChatListItem>(collectionView: cv) { cv, indexPath, item in
                cv.dequeueConfiguredReusableCell(using: reg, for: indexPath, item: item)
            }
        }

        func update(parent: MessageListView, collectionView cv: UICollectionView) {
            self.parent = parent
            self.messagesById = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let items = buildChatItems(parent.messages, isBusy: parent.isBusy)
            let agentChanged = (lastAgentId != parent.agentId)
            wasAtBottom = nearBottom(cv)  // capture BEFORE applying

            var snap = NSDiffableDataSourceSnapshot<Int, ChatListItem>()
            snap.appendSections([0])
            snap.appendItems(items, toSection: 0)

            if agentChanged {
                lastAgentId = parent.agentId
                dataSource.apply(snap, animatingDifferences: false) { [weak self] in
                    self?.scrollToBottom(animated: false)
                }
            } else {
                let stick = wasAtBottom
                dataSource.apply(snap, animatingDifferences: true) { [weak self] in
                    if stick { self?.scrollToBottom(animated: true) }
                }
            }

            if parent.scrollToBottomToken != lastToken {
                lastToken = parent.scrollToBottomToken
                scrollToBottom(animated: true)
            }
        }

        private var messages: [ChatMessage] { parent.messages }

        func scrollToBottom(animated: Bool) {
            guard let cv = collectionView else { return }
            let count = dataSource.snapshot().numberOfItems
            guard count > 0 else { return }
            cv.scrollToItem(at: IndexPath(item: count - 1, section: 0), at: .bottom, animated: animated)
        }

        private func nearBottom(_ cv: UICollectionView) -> Bool {
            isNearBottom(offsetY: cv.contentOffset.y,
                         contentHeight: cv.contentSize.height,
                         boundsHeight: cv.bounds.height,
                         bottomInset: cv.adjustedContentInset.bottom,
                         threshold: 160)
        }

        // MARK: UICollectionViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let cv = collectionView else { return }
            let up = !nearBottom(cv)
            guard up != parent.isScrolledUp else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.isScrolledUp = up }
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  case .message(let id) = item,
                  let msg = messagesById[id], msg.role == .assistant else { return }
            parent.onMessageRead(id)
        }

        // MARK: Keyboard — re-pin to bottom if we were at the bottom

        func observeKeyboard() {
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(keyboardChange),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
            nc.addObserver(self, selector: #selector(keyboardChange),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
        }

        @objc private func keyboardChange() {
            guard wasAtBottom else { return }
            DispatchQueue.main.async { [weak self] in self?.scrollToBottom(animated: false) }
        }

        func teardown() { NotificationCenter.default.removeObserver(self) }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -25
```
Expected: `BUILD SUCCEEDED`. (`MessageListView` is not yet referenced — this just confirms it compiles.)

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/MessageListView.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): MessageListView — UICollectionView hosting SwiftUI message cells"
```

---

## Task 3: Integrate into `ChatView` + remove the old scroll machinery + keep socket up

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

This is surgical. Work by content (line numbers shift). After editing, the file must compile and `ChatViewAgentFilterTests` must still pass.

- [ ] **Step 1: Add the FAB token state**

In `ChatView`'s `@State` block (near `@State private var isScrolledUp = false`), add:

```swift
    @State private var scrollToBottomToken = 0
```

- [ ] **Step 2: Replace the message-list `else` branch with `MessageListView`**

Find the `else {` branch of the content `if visibleMessages.isEmpty … { EmptyStateView … } else { … }` — it currently contains `ZStack(alignment: .bottomTrailing) { GeometryReader { geo in ScrollViewReader { proxy in ScrollView { … } .defaultScrollAnchor(.bottom) … many modifiers … } } ; if isScrolledUp { scrollToBottomFAB } }`. Replace the ENTIRE `else { … }` body with:

```swift
            } else {
                ZStack(alignment: .bottomTrailing) {
                    MessageListView(
                        messages: visibleMessages,
                        agentId: active.active.rawValue,
                        isBusy: activeBusy,
                        onImageTap: { thumb, sha in
                            fullScreenImage = FullScreenImagePresentation(sha: sha, fallback: thumb)
                        },
                        onFeedback: { messageId, isPositive in
                            coordinator.sendFeedback(messageId: messageId, value: isPositive, messageText: visibleMessages.first(where: { $0.id == messageId })?.text ?? "")
                        },
                        onActionTap: { messageId, buttonId, buttonLabel in
                            coordinator.sendActionResponse(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
                        },
                        onRetry: { id in coordinator.ws.retrySend(id: id) },
                        onMessageRead: { id in ws.sendMessageRead(id) },
                        audioPlayer: coordinator.audioPlayer,
                        isScrolledUp: $isScrolledUp,
                        scrollToBottomToken: scrollToBottomToken
                    )
                    .ignoresSafeArea(.container, edges: .bottom)

                    if isScrolledUp {
                        scrollToBottomFAB
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .transition(.opacity)
            }
```

(Note: the old per-row `onFeedback` captured the row's `msg.text`; here we resolve it from `visibleMessages` by id, preserving the feedback-quote behavior.)

- [ ] **Step 3: Point the FAB at the token**

Find `private var scrollToBottomFAB: some View { … .onTapGesture { scrollToBottomAction?() } … }`. Change the tap to:

```swift
            .onTapGesture { scrollToBottomToken += 1 }
```

- [ ] **Step 4: Delete the dead scroll machinery**

Delete these, all now unused (search by name):

1. The helper structs at the top of the file: `ChatScrollOffsetKey`, `ScrolledUpDetector`.
2. The bottom-of-file helper: `BottomSizeChangesAnchor`.
3. The method `repinOnKeyboardChange(_:)`.
4. The `@State private var renderedAgent` and the `@State private var scrollToBottomAction: (() -> Void)?` (the FAB now uses the token).
5. In `recomputeVisibleMessages()`, remove the `renderedAgent = active.active` line (keep `visibleMessages = computeVisibleMessages()`).

If a deletion leaves an unused symbol referenced elsewhere, the compiler will flag it — fix by removing that reference too.

- [ ] **Step 5: Remove the on-disappear disconnect (keep socket up)**

Find and DELETE this modifier on the `ChatView` body:

```swift
        .onDisappear {
            coordinator.disconnect()
        }
```

(The socket is connected once at launch via `ContentView` and stays up; the explicit "reconnect" control in the right drawer remains. Agent switching never connects/disconnects.)

- [ ] **Step 6: Build to verify it compiles**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -25
```
Expected: `BUILD SUCCEEDED`. If the compiler reports a leftover reference to a deleted symbol (`scrollToBottomAction`, `renderedAgent`, `ScrolledUpDetector`, `BottomSizeChangesAnchor`, `repinOnKeyboardChange`, `ChatScrollOffsetKey`), remove that reference and rebuild.

- [ ] **Step 7: Regression test**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:JarvisAppTests/ChatViewAgentFilterTests 2>&1 | tail -20
```
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "feat(ios): chat list uses MessageListView; drop SwiftUI scroll machinery + view-lifecycle disconnect"
```

---

## Task 4: Version bump, full suite, manual device verification

**Files:**
- Modify: `ios/JarvisApp/project.yml`

- [ ] **Step 1: Bump version**

In `ios/JarvisApp/project.yml`, bump `MARKETING_VERSION` to `"1.6.0"` and `CURRENT_PROJECT_VERSION` to the next integer above the current value (currently `26` → set `27`).

- [ ] **Step 2: Regenerate + full unit suite**

```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests 2>&1 | tail -8
```
Expected: `TEST SUCCEEDED` — all suites green incl. `ChatListItemTests`.

- [ ] **Step 3: Manual device verification (Sergei, on the iPhone — build 27)**

Confirm the behavior contract:
- Cycle through ALL agents in order, repeatedly → each opens **instantly on the newest message**, no blank, no visible scroll, never needs a manual scroll (including the tall-table agents).
- New inbound message while at bottom → follows to it; while scrolled up → stays put + FAB shows; tap FAB → jumps to bottom.
- Keyboard open/close in an image-heavy chat → stays pinned, no black gap.
- Image tap / 👍👎 / retry / audio playback still work.
- Switching agents and entering/leaving the chat never reconnects the socket (no connection flicker).

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "chore(ios): bump to 1.6.0 (build 27) — UIKit-backed chat list"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** behavior contract → Task 2 (scroll control) + Task 4 (manual matrix). UICollectionView + diffable + UIHostingConfiguration cells → Task 2. `ChatListItem`/`buildChatItems`/`isNearBottom` → Task 1. ChatView swap + delete machinery → Task 3. WS one-socket / no view-lifecycle disconnect → Task 3 Step 5. Removed-list (ScrolledUpDetector/ChatScrollOffsetKey/BottomSizeChangesAnchor/repinOnKeyboardChange/renderedAgent/scroll onChanges) → Task 3 Step 4. Testing (pure units + manual) → Tasks 1 & 4. Non-goals (inline actions, paging, inversion) untouched.
- **Type consistency:** `ChatListItem` cases (`.date(Date)`, `.message(String)`, `.thinking`) identical in Task 1 + Task 2. `buildChatItems(_:isBusy:)` / `isNearBottom(offsetY:contentHeight:boundsHeight:bottomInset:threshold:)` signatures match across tasks. `MessageListView` init params (incl. `onMessageRead`, `scrollToBottomToken`, `$isScrolledUp`) match the call site in Task 3. `MessageRow` init labels match the existing component. `DateSeparator(date:)` / `ThinkingRow(detail:)` match existing components.
- **Placeholder scan:** none — every code step is complete.
- **Note:** Task 3 is the integration risk (large ChatView edit); Steps 4-6 list every symbol to delete so the compiler pinpoints leftovers.
