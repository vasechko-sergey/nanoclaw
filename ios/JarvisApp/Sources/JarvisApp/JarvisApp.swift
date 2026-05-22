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
