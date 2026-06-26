import SwiftUI
import UIKit

/// UIKit-backed chat list, **inverted** (transform-flipped) so the newest message
/// sits at content-offset 0 — the visual bottom. Inversion makes "scroll to
/// bottom" a content-offset reset that needs NO knowledge of content size, so the
/// list lands on the newest message instantly even with self-sizing cells whose
/// heights settle after layout — eliminating the top→bottom scroll/slide a
/// non-inverted jump-to-bottom hit on tall-content (big-table) agents. Cells host
/// the existing SwiftUI `MessageRow` / `DateSeparator` / `ThinkingRow` via
/// `UIHostingConfiguration`; each cell is un-flipped so its content is upright.
struct MessageListView: UIViewRepresentable {
    let messages: [ChatMessage]
    let agentId: String
    let isBusy: Bool
    var onImageTap: (UIImage, String?) -> Void
    var onFeedback: (String, Bool) -> Void
    var onActionTap: (String, String, String) -> Void
    var onWorkoutStart: ((WorkoutPlan, String) -> Void)? = nil
    var onWorkoutCancel: ((String) -> Void)? = nil
    var onRetry: (String) -> Void
    var onMessageRead: (String) -> Void
    var audioPlayer: AudioPlaybackService?
    /// Called (main thread) when the at-bottom state flips. The parent wraps the
    /// state write in an animation so the FAB animates in/out.
    var onScrolledUpChange: (Bool) -> Void
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
        // Inverted: flip vertically so item 0 (newest) renders at the bottom and
        // the bottom is the MINIMUM content offset.
        cv.transform = CGAffineTransform(scaleX: 1, y: -1)
        // A flipped vertical indicator would sit on the wrong side; hide it (the
        // FAB provides jump-to-bottom).
        cv.showsVerticalScrollIndicator = false
        cv.delegate = context.coordinator
        // Tap-to-dismiss: tapping the chat area (not the keyboard) resigns the
        // input bar's first responder. cancelsTouchesInView=false + simultaneous
        // recognition (delegate) so cell taps — action buttons, images, the
        // workout card — still fire. The UIKit list otherwise swallows the taps
        // that a SwiftUI .onTapGesture used to catch before the rewrite.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleDismissTap))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        cv.addGestureRecognizer(tap)
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

    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        private var parent: MessageListView
        private var dataSource: UICollectionViewDiffableDataSource<Int, ChatListItem>!
        private weak var collectionView: UICollectionView?
        private var messagesById: [String: ChatMessage] = [:]
        private var lastAgentId: String?
        private var lastToken: Int = 0
        private var wasAtBottom = true
        private var lastPushedScrolledUp: Bool?

        init(_ parent: MessageListView) { self.parent = parent }

        func configureDataSource(_ cv: UICollectionView) {
            collectionView = cv
            // One registration PER item kind. A single shared registration made a
            // reused cell host different SwiftUI types (DateSeparator → ThinkingRow
            // → MessageRow), so UIHostingConfiguration's content-view TYPE changed
            // on reuse — forcing UIKit to replace the whole content view instead of
            // updating in place (the "existing content view does not support the new
            // configuration … which is expensive" console warning). Splitting by kind
            // means each cell only ever hosts one content-view type → in-place update.
            //
            // The collection view is y-flipped (inverted list); each hosted view is
            // un-flipped with a scaleEffect — done inside the hosted view so it
            // survives UICollectionView re-applying layout attributes mid-scroll.
            let dateReg = UICollectionView.CellRegistration<UICollectionViewListCell, Date> { cell, _, day in
                Self.clearBackground(cell)
                cell.contentConfiguration = UIHostingConfiguration {
                    DateSeparator(date: day).scaleEffect(x: 1, y: -1)
                }
                .margins(.all, 0)
            }
            let thinkingReg = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
                Self.clearBackground(cell)
                cell.contentConfiguration = UIHostingConfiguration {
                    ThinkingRow(detail: nil).scaleEffect(x: 1, y: -1)
                }
                .margins(.all, 0)
            }
            let messageReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
                Self.clearBackground(cell)
                guard let self, let msg = self.messagesById[id] else {
                    cell.contentConfiguration = nil
                    return
                }
                let isLast = (self.parent.messages.last?.id == id)
                cell.contentConfiguration = UIHostingConfiguration {
                    MessageRow(
                        message: msg,
                        isLast: isLast,
                        onImageTap: self.parent.onImageTap,
                        onFeedback: self.parent.onFeedback,
                        onActionTap: self.parent.onActionTap,
                        onWorkoutStart: self.parent.onWorkoutStart,
                        onWorkoutCancel: self.parent.onWorkoutCancel,
                        onRetry: self.parent.onRetry,
                        audioPlayer: self.parent.audioPlayer
                    )
                    .scaleEffect(x: 1, y: -1)
                }
                .margins(.all, 0)
            }
            dataSource = UICollectionViewDiffableDataSource<Int, ChatListItem>(collectionView: cv) { cv, indexPath, item in
                switch item {
                case .date(let day):
                    return cv.dequeueConfiguredReusableCell(using: dateReg, for: indexPath, item: day)
                case .thinking:
                    return cv.dequeueConfiguredReusableCell(using: thinkingReg, for: indexPath, item: 0)
                case .message(let id):
                    return cv.dequeueConfiguredReusableCell(using: messageReg, for: indexPath, item: id)
                }
            }
        }

        /// Transparent cell background (the chat surface paints its own).
        private static func clearBackground(_ cell: UICollectionViewListCell) {
            var bg = UIBackgroundConfiguration.listCell()
            bg.backgroundColor = .clear
            cell.backgroundConfiguration = bg
        }

        func update(parent: MessageListView, collectionView cv: UICollectionView) {
            self.parent = parent
            self.messagesById = Dictionary(parent.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Inverted list → newest first (index 0 = visual bottom). Reversing the
            // oldest-first builder output keeps date separators correctly placed
            // (a separator ends up just above the first message of its day on screen).
            let items = Array(buildChatItems(parent.messages, isBusy: parent.isBusy).reversed())
            let agentChanged = (lastAgentId != parent.agentId)
            if agentChanged { lastAgentId = parent.agentId }
            let tokenChanged = (parent.scrollToBottomToken != lastToken)
            if tokenChanged { lastToken = parent.scrollToBottomToken }
            wasAtBottom = nearBottom(cv)
            let stick = wasAtBottom

            var snap = NSDiffableDataSourceSnapshot<Int, ChatListItem>()
            snap.appendSections([0])
            snap.appendItems(items, toSection: 0)

            if agentChanged {
                // Switch: apply non-animated, then pin to newest (the MINIMUM
                // offset). Offset-min needs no content size, so it is correct
                // immediately — even before self-sizing settles — with no visible
                // scroll or slide.
                dataSource.apply(snap, animatingDifferences: false)
                pinToNewest(cv, animated: false)
            } else {
                dataSource.apply(snap, animatingDifferences: true) { [weak self] in
                    guard let self, let cv = self.collectionView else { return }
                    if tokenChanged || stick { self.pinToNewest(cv, animated: true) }
                }
            }
        }

        /// Pin to the newest message = the MINIMUM content offset (top of the
        /// inverted scroll range = the visual bottom). Independent of content size.
        func pinToNewest(_ cv: UICollectionView, animated: Bool) {
            let minY = -cv.adjustedContentInset.top
            cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: minY), animated: animated)
        }

        /// "At bottom" in the inverted list = near the minimum offset (newest).
        private func nearBottom(_ cv: UICollectionView) -> Bool {
            (cv.contentOffset.y + cv.adjustedContentInset.top) <= 160
        }

        // MARK: UICollectionViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let cv = collectionView else { return }
            let up = !nearBottom(cv)
            guard up != lastPushedScrolledUp else { return }
            lastPushedScrolledUp = up
            DispatchQueue.main.async { [weak self] in self?.parent.onScrolledUpChange(up) }
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  case .message(let id) = item,
                  let msg = messagesById[id], msg.role == .assistant else { return }
            parent.onMessageRead(id)
        }

        // MARK: Keyboard — re-pin to newest if we were at the bottom

        func observeKeyboard() {
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(keyboardChange),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
            nc.addObserver(self, selector: #selector(keyboardChange),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
        }

        @objc private func keyboardChange() {
            guard wasAtBottom, let cv = collectionView else { return }
            DispatchQueue.main.async { [weak self] in self?.pinToNewest(cv, animated: false) }
        }

        func teardown() { NotificationCenter.default.removeObserver(self) }

        // MARK: Tap-to-dismiss keyboard

        /// Resign first responder app-wide. The input bar's TextField lives in a
        /// separate SwiftUI hierarchy (not under the collection view), so an
        /// app-wide resign is what reaches it — same as ChatView.dismissKeyboard.
        @objc func handleDismissTap() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        /// Fire alongside cell/scroll gestures so the tap-to-dismiss never blocks
        /// a button, image, or the workout card from also handling the touch.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
