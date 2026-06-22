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
        private var lastPushedScrolledUp: Bool?

        init(_ parent: MessageListView) { self.parent = parent }

        func configureDataSource(_ cv: UICollectionView) {
            collectionView = cv
            let reg = UICollectionView.CellRegistration<UICollectionViewListCell, ChatListItem> { [weak self] cell, _, item in
                guard let self else { return }
                var bg = UIBackgroundConfiguration.listCell()
                bg.backgroundColor = .clear
                cell.backgroundConfiguration = bg
                // The collection view is y-flipped (inverted list). Un-flip the
                // CONTENT with a SwiftUI scaleEffect — doing it here (inside the
                // hosted view) survives UICollectionView re-applying layout
                // attributes mid-scroll, which would reset a `cell.transform`.
                switch item {
                case .date(let day):
                    cell.contentConfiguration = UIHostingConfiguration {
                        DateSeparator(date: day).scaleEffect(x: 1, y: -1)
                    }
                    .margins(.all, 0)
                case .thinking:
                    cell.contentConfiguration = UIHostingConfiguration {
                        ThinkingRow(detail: nil).scaleEffect(x: 1, y: -1)
                    }
                    .margins(.all, 0)
                case .message(let id):
                    guard let msg = self.messagesById[id] else {
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
                            onRetry: self.parent.onRetry,
                            audioPlayer: self.parent.audioPlayer
                        )
                        .scaleEffect(x: 1, y: -1)
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
    }
}
