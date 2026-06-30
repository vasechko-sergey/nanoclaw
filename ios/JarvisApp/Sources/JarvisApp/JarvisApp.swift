import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Static hook the coordinator sets at init to receive proactive fires
    /// from the notification delegate. Production wiring lives in AppCoordinator.
    static var dispatchProactive: ((String, [String: Any]) -> Void)?

    /// Deep-link hooks the coordinator wires at init: a tapped notification is
    /// routed (via `NotificationTapRouter`) into one of these, which set the
    /// coordinator's nav-intent flags. The view layer applies the navigation.
    static var openSummaryBoard: (() -> Void)?
    static var openAgentChat: ((AgentIdentity) -> Void)?

    func application(
        _ app: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        NotificationCategories.register()
        // Authoritative foreground tracking for the notification gate. SwiftUI
        // scenePhase.onChange does NOT fire for the launch phase (initial value),
        // so AppForegroundState could stay stale and the gate read "active" while
        // backgrounded — suppressing a background notification. UIApplication
        // lifecycle notifications fire on the main thread for every real
        // transition, including the first activation. didEnterBackground (not
        // willResignActive) so a transient .inactive (control center / shade)
        // doesn't flip us to "backgrounded" while still on screen.
        AppForegroundState.isActive = (app.applicationState == .active)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            AppForegroundState.isActive = true
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            AppForegroundState.isActive = false
        }
        // Time-based morning backstop: a daily ~08:00 upload floor even when no
        // new-sample wake fires. register() MUST run before launch finishes
        // (BGTaskScheduler requirement), so it stays synchronous here.
        HealthBackgroundTask.register()
        HealthBackgroundTask.schedule()
        PendingRefreshTask.register()
        PendingRefreshTask.schedule()
        // Passive background health sync (HealthKit background delivery → HTTP
        // upload). Deferred OFF the launch critical path: registering 12
        // observers + their first-fire fetch/upload fan-out at cold launch
        // spiked CPU/memory and competed with first paint (slow starts +
        // occasional launch jettison). Background delivery is unaffected —
        // observers just register a moment after the UI is up.
        Task.detached(priority: .utility) {
            HealthSync.start()
        }
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

    // Tap (or reply-action) on a notification. `NotificationTapRouter` maps the
    // category/action to a target: reply → POST to host (unchanged behavior);
    // summary-ready → open the Сводка board; agent-message default tap →
    // deep-link into that agent's chat. `.none` just dismisses.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        let target = NotificationTapRouter.route(
            categoryId: response.notification.request.content.categoryIdentifier,
            actionId: response.actionIdentifier,
            replyText: replyText,
            userInfo: response.notification.request.content.userInfo
        )
        switch target {
        case let .reply(agentId, text):
            NotificationReplySender.shared.send(agentId: agentId, text: text) { _ in completionHandler() }
            return
        case .openSummaryBoard:
            AppDelegate.openSummaryBoard?()
        case let .openAgentChat(agent):
            AppDelegate.openAgentChat?(agent)
        case .none:
            break
        }
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
            ContentView(coordinator: coordinator)
                .environment(settings)
                .environment(coordinator)
                .environment(activeAgent)
                .onChange(of: scenePhase) { _, new in
                    // isActive is tracked authoritatively via UIApplication
                    // lifecycle notifications (see AppDelegate) — not here.
                    if new == .active {
                        Theme.refreshScale()
                        Theme.refreshDrawerWidth()
                        HealthSync.kickIfStale()
                    }
                    if new == .background {
                        // Re-arm the morning upload + pending pull each time we background.
                        HealthBackgroundTask.schedule()
                        PendingRefreshTask.schedule()
                    }
                    Task { @MainActor in
                        coordinator.ws.handleScenePhase(new)
                    }
                }
        }
    }
}
