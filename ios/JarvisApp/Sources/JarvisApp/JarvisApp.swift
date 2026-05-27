import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var wsClient: WebSocketClient?
    /// Set by AppCoordinator — opens the conversation a proactive push refers to.
    static var onOpenConversation: ((String) -> Void)?

    func application(
        _ app: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // Passive background health sync (HealthKit background delivery → HTTP upload).
        HealthSync.start()
        return true
    }


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

    // Show proactive pushes even while the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Tap on a proactive push → deep-link into the referenced conversation.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let cid = response.notification.request.content.userInfo["conversationId"] as? String {
            AppDelegate.onOpenConversation?(cid)
        }
        completionHandler()
    }
}

@main
struct JarvisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var settings: AppSettings
    @State private var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    init() {
        let s = AppSettings()
        _settings = State(initialValue: s)
        _coordinator = State(initialValue: AppCoordinator(settings: s))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .environment(settings)
                .environment(coordinator)
                .onChange(of: scenePhase) { _, new in
                    Task { @MainActor in
                        coordinator.ws.handleScenePhase(new)
                    }
                }
        }
    }
}
