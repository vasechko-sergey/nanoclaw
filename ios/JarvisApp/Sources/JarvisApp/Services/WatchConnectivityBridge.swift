import Foundation
import WatchConnectivity

/// iOS-side WCSession bridge. The iPhone forwards new assistant messages to
/// the watch via `transferUserInfo`, and receives dictated text from the watch
/// via `didReceiveMessage`. The bridge itself is stateless — payload-building
/// and parsing are static so they unit-test without a live WCSession.
@MainActor final class WatchConnectivityBridge: NSObject, WCSessionDelegate {

    /// Called when the watch sends dictated text. AppCoordinator routes it to
    /// `coordinator.sendMessage(text, viaVoice: true)`.
    var onWatchDictation: ((String) -> Void)?

    private let session: WCSession?

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        if let s = session {
            s.delegate = self
            s.activate()
        }
    }

    /// Push a fresh assistant message to the paired watch. Best-effort —
    /// returns false when the session isn't reachable.
    @discardableResult
    func pushAssistantMessage(id: String, text: String, timestamp: Date) -> Bool {
        guard let s = session, s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else {
            return false
        }
        let payload = Self.buildAssistantPayload(id: id, text: text, timestamp: timestamp)
        s.transferUserInfo(payload)
        return true
    }

    // MARK: – Payload helpers (testable)

    nonisolated static func buildAssistantPayload(id: String, text: String, timestamp: Date) -> [String: Any] {
        return [
            "type": "message",
            "id": id,
            "text": text,
            "ts": ISO8601DateFormatter().string(from: timestamp),
        ]
    }

    nonisolated static func parseSendText(_ dict: [String: Any]) -> String? {
        guard let type = dict["type"] as? String, type == "send_text" else { return nil }
        guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: – WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error { Log.warn(.watch, "[WC] activation error: \(error)") }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // iOS recommends re-activating after deactivation when the user pairs
        // a different watch.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let text = Self.parseSendText(message) else { return }
        Task { @MainActor [weak self] in
            self?.onWatchDictation?(text)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        if let text = Self.parseSendText(message) {
            Task { @MainActor [weak self] in
                self?.onWatchDictation?(text)
            }
        }
        replyHandler(["ok": true])
    }
}
