import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    static weak var wsClient: WebSocketClient?

    func application(
        _ app: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken token: Data
    ) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        AppDelegate.wsClient?.registerApnsToken(hex)
    }

    func application(
        _ app: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error)")
    }
}

@main
struct JarvisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var settings = AppSettings()
    @StateObject private var coordinator: AppCoordinator

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _coordinator = StateObject(wrappedValue: AppCoordinator(settings: s))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .environmentObject(settings)
                .environmentObject(coordinator)
        }
    }
}
