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
        private var lastPushedScrolledUp: Bool?

        init(_ parent: MessageListView) { self.parent = parent }

        func configureDataSource(_ cv: UICollectionView) {
            collectionView = cv
            let reg = UICollectionView.CellRegistration<UICollectionViewListCell, ChatListItem> { [weak self] cell, _, item in
                guard let self else { return }
                var bg = UIBackgroundConfiguration.listCell()
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
            self.messagesById = Dictionary(parent.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let items = buildChatItems(parent.messages, isBusy: parent.isBusy)
            let agentChanged = (lastAgentId != parent.agentId)
            if agentChanged { lastAgentId = parent.agentId }
            let tokenChanged = (parent.scrollToBottomToken != lastToken)
            if tokenChanged { lastToken = parent.scrollToBottomToken }
            wasAtBottom = nearBottom(cv)          // capture BEFORE applying
            let stick = wasAtBottom

            var snap = NSDiffableDataSourceSnapshot<Int, ChatListItem>()
            snap.appendSections([0])
            snap.appendItems(items, toSection: 0)

            // One apply; all scroll decisions run in its completion, AFTER the
            // snapshot is committed and laid out (so scrollToItem reaches a real
            // frame). Agent switch → instant bottom; FAB token → animated bottom;
            // otherwise stay pinned only if we were already at the bottom.
            dataSource.apply(snap, animatingDifferences: !agentChanged) { [weak self] in
                guard let self else { return }
                if agentChanged || tokenChanged {
                    self.scrollToBottom(animated: !agentChanged)
                } else if stick {
                    self.scrollToBottom(animated: true)
                }
            }
        }

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
            guard up != lastPushedScrolledUp else { return }
            lastPushedScrolledUp = up
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
