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
