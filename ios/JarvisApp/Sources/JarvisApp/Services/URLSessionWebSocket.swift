import Foundation

/// Production `WebSocketLike` backed by `URLSessionWebSocketTask`.
///
/// Behavior:
/// - `connect()` opens the task, then schedules a permanent receive loop and a 25s ping timer.
/// - Each received frame (data or string) is forwarded as `Data` to `onMessage`.
/// - On any receive error or ping failure, `onClose` fires once and the socket tears down.
/// - `close()` is idempotent and cancels the ping timer, the task, and the session.
///
/// The class is `@unchecked Sendable` because the underlying `URLSession*` types are
/// thread-safe and the mutable state (`task`, `session`, `pingTimer`, callbacks) is only
/// touched from the main thread (timer block) or the URLSession completion queue
/// (receive/ping callbacks). Callers that read `onMessage` / `onClose` must accept the
/// same threading assumption — `TransportV2` hops into its actor before mutating state.
final class URLSessionWebSocket: NSObject, WebSocketLike, @unchecked Sendable {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var didFireClose = false

    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(url: URL) {
        self.url = url
        super.init()
    }

    func connect() async throws {
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        didFireClose = false
        task.resume()
        startReceiveLoop(task: task)
        startPingTimer(task: task)
    }

    func send(_ data: Data) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        try await task.send(.data(data))
    }

    func close() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Private

    private func fireCloseOnce(_ error: Error?) {
        guard !didFireClose else { return }
        didFireClose = true
        onClose?(error)
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fireCloseOnce(error)
            case .success(let message):
                switch message {
                case .data(let d):
                    self.onMessage?(d)
                case .string(let s):
                    self.onMessage?(Data(s.utf8))
                @unknown default:
                    break
                }
                // Only continue if the task we started is still the current one
                // (close() nils it out; we don't want a runaway loop).
                if let task, task === self.task {
                    self.startReceiveLoop(task: task)
                }
            }
        }
    }

    private func startPingTimer(task: URLSessionWebSocketTask) {
        let timer = Timer(timeInterval: 25, repeats: true) { [weak self, weak task] _ in
            guard let task else {
                self?.pingTimer?.invalidate()
                return
            }
            task.sendPing { [weak self] err in
                if let err {
                    self?.fireCloseOnce(err)
                    self?.close()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }
}
