import Network

/// Текущий тип сетевого соединения для контекста агента ("wifi" / "cellular" / "offline").
/// Также вызывает `onSatisfied` каждый раз когда сеть становится доступной — используется
/// `WebSocketClient` для немедленного реконнекта на переключении wifi/cellular.
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private let monitor = NWPathMonitor()
    private(set) var status = ""

    /// Called when network path becomes `.satisfied`. Dispatched on the main queue.
    var onSatisfied: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status != .satisfied {
                self?.status = "offline"
            } else if path.usesInterfaceType(.wifi) {
                self?.status = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                self?.status = "cellular"
            } else {
                self?.status = "online"
            }

            if path.status == .satisfied {
                DispatchQueue.main.async { self?.onSatisfied?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "connectivity.monitor"))
    }
}
