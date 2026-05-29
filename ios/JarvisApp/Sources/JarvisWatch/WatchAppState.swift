import Foundation
import WatchConnectivity

/// In-memory model for the watch app. Pulls assistant messages from the
/// paired iPhone over WCSession and exposes a tap-to-dictate flow that uses
/// WKApplication.presentTextInputController (Apple's built-in dictation sheet,
/// since SFSpeechRecognizer is unavailable on watchOS).
@Observable @MainActor final class WatchAppState: NSObject, WCSessionDelegate {

    struct ReceivedMessage: Identifiable, Equatable {
        let id: String
        let text: String
        let timestamp: Date
    }

    var messages: [ReceivedMessage] = []
    var isConnectedToPhone: Bool = false

    static let maxMessages = 50

    @ObservationIgnored private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil

    override init() {
        super.init()
        if let s = session {
            s.delegate = self
            s.activate()
            isConnectedToPhone = (s.activationState == .activated)
        }
    }

    // MARK: – Receiving assistant messages

    private func appendIfMessage(_ dict: [String: Any]) {
        guard let type = dict["type"] as? String, type == "message",
              let id = dict["id"] as? String,
              let text = dict["text"] as? String else { return }
        let ts: Date = {
            if let s = dict["ts"] as? String, let d = ISO8601DateFormatter().date(from: s) { return d }
            return Date()
        }()
        messages.append(.init(id: id, text: text, timestamp: ts))
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }

    // MARK: – Send dictated text to phone

    func sendDictatedTextToPhone(_ text: String) {
        guard !text.isEmpty else { return }
        guard let s = session, s.isReachable else { return }
        s.sendMessage(["type": "send_text", "text": text], replyHandler: nil) { error in
            print("[Watch WC] sendMessage error: \(error)")
        }
    }

    // MARK: – WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor [weak self] in
            self?.isConnectedToPhone = (activationState == .activated)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor [weak self] in
            self?.appendIfMessage(userInfo)
        }
    }
}
