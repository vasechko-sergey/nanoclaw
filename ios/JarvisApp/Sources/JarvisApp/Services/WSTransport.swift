import Foundation

// MARK: - WSTransport
//
// Owns the URLSessionWebSocketTask, reconnect-with-backoff, heartbeat
// ping/pong, and force-reconnect. Knows nothing about message types or
// the outbox — it just shovels bytes either direction.
//
// Caller (WebSocketClient) wires three callbacks:
//   * onConnectionChanged: connection-state observer (UI bit + post-connect actions)
//   * onMessage: raw URLSessionWebSocketTask.Message for the inbound dispatcher
//   * onAuthPayload: returns the JSON `auth` payload to send right after connect
//
// All public methods are @MainActor — the entire transport lives on the main actor,
// matching WebSocketClient.

@MainActor
final class WSTransport {
    private(set) var isConnected = false {
        didSet { if isConnected != oldValue { onConnectionChanged?(isConnected) } }
    }

    private var task: URLSessionWebSocketTask?
    private var settings: AppSettings?
    private var reconnectDelay: TimeInterval = 1
    private var heartbeatTimer: Timer?
    internal var lastPongAt: Date = .distantPast
    private let pingInterval: TimeInterval = 25
    private let pongTimeout: TimeInterval = 35
    private var stopped = false

    /// Fires on every transition of `isConnected`.
    var onConnectionChanged: ((Bool) -> Void)?

    /// Raw inbound — caller decodes and dispatches.
    var onMessage: ((URLSessionWebSocketTask.Message) -> Void)?

    /// Caller constructs the auth JSON given the active AppSettings — keeps the
    /// transport unaware of token/platformId semantics.
    var onAuthPayload: ((AppSettings) -> Data?)?

    /// Test seam: fires from `notifyConnectedForTesting()`.
    var onConnectedForTesting: (() -> Void)?

    func connect(settings: AppSettings) {
        self.settings = settings
        stopped = false
        doConnect(settings: settings)
    }

    func disconnect() {
        stopHeartbeat()
        stopped = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
    }

    /// Best-effort send. No-op when not connected — caller is expected to
    /// guard with `isConnected` first if it needs to know.
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void = { _ in }) {
        guard let ws = task else { completion(nil); return }
        ws.send(.data(data), completionHandler: completion)
    }

    @MainActor
    func forceReconnect(reason: String) {
        Log.info(.ws, "reconnect: \(reason)")
        task?.cancel(with: .goingAway, reason: nil)
        isConnected = false
        reconnectDelay = 1
        stopHeartbeat()
        guard !stopped, let settings else { return }
        doConnect(settings: settings)
    }

    /// Call this when the application becomes active. If we lost the socket
    /// silently in the background we'll re-establish; otherwise we just nudge
    /// the heartbeat to detect stale-pong fast.
    @MainActor
    func handleBecameActive() {
        if !isConnected, !stopped, let settings {
            doConnect(settings: settings)
        } else if isConnected {
            tickHeartbeat()
        }
    }

    /// Marks the transport connected and runs the test-only callback. Lets
    /// tests assert post-connect side-effects without spinning up a socket.
    @MainActor
    func notifyConnectedForTesting() {
        isConnected = true
        onConnectedForTesting?()
    }

    // MARK: – Heartbeat

    func startHeartbeat() {
        heartbeatTimer?.invalidate()
        lastPongAt = Date()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickHeartbeat() }
        }
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    @MainActor
    internal func tickHeartbeat() {
        guard let ws = task, isConnected else { return }
        if Date().timeIntervalSince(lastPongAt) > pongTimeout {
            forceReconnect(reason: "pong timeout")
            return
        }
        ws.sendPing { [weak self] error in
            Task { @MainActor in
                if error == nil { self?.lastPongAt = Date() }
                else { self?.forceReconnect(reason: "ping failed") }
            }
        }
    }

    /// Test seam: stale-pong path without a live URLSessionWebSocketTask.
    /// The real `tickHeartbeat()` early-returns when `task == nil`, so this
    /// inlines just the stale-pong check.
    @MainActor
    internal func tickHeartbeatForTesting() {
        if Date().timeIntervalSince(lastPongAt) > pongTimeout {
            forceReconnect(reason: "pong timeout (test)")
        }
    }

    // MARK: – Private

    private func doConnect(settings: AppSettings) {
        stopHeartbeat()
        guard !stopped else { return }
        let rawUrl: String
        if JarvisApp.isUITesting {
            rawUrl = "ws://127.0.0.1:8765"
        } else {
            guard !settings.serverURL.isEmpty else { return }
            rawUrl = settings.serverURL
        }
        var s = rawUrl
        if      s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) }
        else if s.hasPrefix("http://")  { s = "ws://"  + s.dropFirst(7) }
        else if !s.hasPrefix("ws")      { s = "ws://"  + s }
        guard let url = URL(string: s) else { return }

        // Cancel any prior task so we never run two concurrent receive loops.
        task?.cancel(with: .normalClosure, reason: nil)

        let ws = URLSession.shared.webSocketTask(with: url)
        self.task = ws
        ws.resume()

        if let authData = onAuthPayload?(settings) {
            ws.send(.data(authData)) { if let e = $0 { Log.warn(.ws, "send(auth) failed: \(e)") } }
        }
        receive(ws: ws)
    }

    private func receive(ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure:
                    // Ignore failures from a socket we've already replaced.
                    guard self.task === ws else { return }
                    self.isConnected = false
                    guard !self.stopped, let settings = self.settings else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.reconnectDelay * 1_000_000_000))
                    self.reconnectDelay = min(self.reconnectDelay * 2, 30)
                    // Re-check: disconnect() may have fired during the sleep.
                    guard !self.stopped else { return }
                    self.doConnect(settings: settings)

                case .success(let msg):
                    self.reconnectDelay = 1
                    self.onMessage?(msg)
                    // Don't keep reading a socket we've replaced or shut down.
                    guard !self.stopped, self.task === ws else { return }
                    self.receive(ws: ws)
                }
            }
        }
    }
}
