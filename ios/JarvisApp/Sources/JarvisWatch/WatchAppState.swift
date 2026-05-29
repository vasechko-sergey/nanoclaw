import Foundation

/// In-memory model for the watch app. The iOS companion pushes new
/// assistant messages via WCSession.transferUserInfo (Task 4 wires WCSession).
/// For now this just owns the rendered list + recording flags.
@Observable @MainActor final class WatchAppState {

    struct ReceivedMessage: Identifiable, Equatable {
        let id: String
        let text: String
        let timestamp: Date
    }

    var messages: [ReceivedMessage] = []
    var isConnectedToPhone: Bool = false
    var isRecording: Bool = false

    /// Latest dictated transcript shown under the mic button while listening.
    var partialTranscript: String = ""

    static let maxMessages = 50

    func append(id: String, text: String, timestamp: Date) {
        messages.append(.init(id: id, text: text, timestamp: timestamp))
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }
}
