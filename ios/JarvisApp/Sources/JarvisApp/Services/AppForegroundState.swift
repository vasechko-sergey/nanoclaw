import Foundation

/// Whether the app is currently foreground-active. Set from the scenePhase
/// observer in `JarvisApp.swift`; read from `LocalNotifier` (any thread) and the
/// `TransportV2` actor to decide whether an inbound message should raise a
/// local notification (active → it's already on screen, no notification).
/// Lock-guarded because writes come from MainActor and reads from background.
enum AppForegroundState {
    private static let lock = NSLock()
    private static var _active = false

    static var isActive: Bool {
        get { lock.withLock { _active } }
        set { lock.withLock { _active = newValue } }
    }
}
