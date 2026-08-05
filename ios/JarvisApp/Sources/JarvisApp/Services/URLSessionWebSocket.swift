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
    /// Serializes `connect()` teardown+setup against `close()`. Both mutate
    /// `session`/`task`, and they run on DIFFERENT threads: `connect()` on the
    /// TransportV2 actor's executor, `close()` from a URLSession ping-failure
    /// callback (`sendPing`'s completion queue). Without this, close() could
    /// `invalidateAndCancel()` the session that connect() had just stored, in
    /// the window before `webSocketTask(with:)` — which throws
    /// 'Task created in a session that has been invalidated' (NSGenericException).
    private let stateLock = NSLock()

    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(url: URL) {
        self.url = url
        super.init()
    }

    func connect() async throws {
        // Reconnects reuse this same instance. Tear down any prior session,
        // task, and ping timer FIRST — otherwise each reconnect orphans a
        // URLSession + a RunLoop-scheduled ping Timer that keep firing, which
        // accumulates over a flaky-network session (memory/FD growth + a
        // saturated main RunLoop).
        //
        // The teardown + fresh session/task creation run under `stateLock` as
        // one atomic step so a concurrent `close()` (on a URLSession callback
        // thread) cannot invalidate the just-stored session between the
        // `self.session =` assignment and `webSocketTask(with:)`. `resume()` and
        // the receive/ping loops are started AFTER unlocking — they don't need
        // the lock and shouldn't hold it during scheduling.
        stateLock.lock()
        teardownLocked()
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        didFireClose = false
        stateLock.unlock()
        task.resume()
        startReceiveLoop(task: task)
        startPingTimer(task: task)
    }

    func send(_ data: Data) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        try await task.send(.data(data))
    }

    func close() {
        stateLock.lock()
        teardownLocked()
        stateLock.unlock()
    }

    // MARK: - Private

    /// Invalidate the ping timer, cancel the task, and invalidate the session.
    /// MUST be called with `stateLock` held — it is the shared teardown body for
    /// both `connect()` (reconnect reuse) and `close()`, and serializing it is
    /// what prevents connect/close from racing on `session`/`task`. Idempotent:
    /// nil fields make a repeat call a no-op.
    private func teardownLocked() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

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
