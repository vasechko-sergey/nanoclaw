import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Static hook the coordinator sets at init to receive proactive fires
    /// from the notification delegate. Production wiring lives in AppCoordinator.
    static var dispatchProactive: ((String, [String: Any]) -> Void)?

    func application(
        _ app: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // Passive background health sync (HealthKit background delivery → HTTP upload).
        HealthSync.start()
        // Time-based morning backstop: a daily ~08:00 upload floor even when no
        // new-sample wake fires. register() MUST run before launch finishes.
        HealthBackgroundTask.register()
        HealthBackgroundTask.schedule()
        return true
    }

    // Show proactive pushes even while the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let info = notification.request.content.userInfo
        if let isProactive = info["proactive"] as? Bool, isProactive,
           let type = info["type"] as? String {
            var payload: [String: Any] = [:]
            for (k, v) in info {
                guard let key = k as? String, key != "proactive", key != "type" else { continue }
                payload[key] = v
            }
            AppDelegate.dispatchProactive?(type, payload)
            completionHandler([.list])
            return
        }
        completionHandler([.banner, .sound])
    }

    // Tap on a proactive push — single-chat mode has no per-conversation
    // deep-link, so we just dismiss the notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

@main
struct JarvisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var settings: AppSettings
    @State private var coordinator: AppCoordinator
    @State private var activeAgent: ActiveAgentState
    @Environment(\.scenePhase) private var scenePhase

    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    init() {
        let s = AppSettings()
        _settings = State(initialValue: s)
        _coordinator = State(initialValue: AppCoordinator(settings: s))
        _activeAgent = State(initialValue: ActiveAgentState())
    }

    var body: some Scene {
        WindowGroup {
            RootAdaptiveView(coordinator: coordinator)
                .environment(settings)
                .environment(coordinator)
                .environment(activeAgent)
                .onChange(of: scenePhase) { _, new in
                    if new == .active {
                        // Theme scale / drawer width are now driven by GeometryReader
                        // in RootAdaptiveView; no UIScreen-based call needed here.
                        HealthSync.kickIfStale()
                    }
                    if new == .background {
                        // Re-arm the morning upload each time we background.
                        HealthBackgroundTask.schedule()
                    }
                    Task { @MainActor in
                        coordinator.ws.handleScenePhase(new)
                    }
                }
        }
    }
}
