import Network

/// Текущий тип сетевого соединения для контекста агента ("wifi" / "cellular" / "offline").
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private let monitor = NWPathMonitor()
    private(set) var status = ""

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
        }
        monitor.start(queue: DispatchQueue(label: "connectivity.monitor"))
    }
}
