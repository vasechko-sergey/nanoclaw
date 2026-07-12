import XCTest
import SwiftUI
import UIKit
import Combine
import GRDB
@testable import Jarvis

/// Live end-to-end render of BOTH Payne coach-hint surfaces, driven by a real
/// inbound `coach_message` frame off the `e2e-harness` fake server (scenario
/// `workout`) — nothing about the coach text is hand-seeded. Unlike the offline
/// `CoachHintRenderTests` (ImageRenderer), this hosts `WorkoutView` in a real
/// `UIWindow` and captures with a UIKit render pass, so the reps/weight steppers
/// paint for real (ImageRenderer draws them as placeholder tiles) and Path A's
/// coach line appears via the genuine `.onReceive` publisher chain.
///
/// Operator must start the harness first (Simulator can't spawn host procs):
///     E2E_SCENARIO=workout E2E_PORT=8801 pnpm run e2e:harness &
///     xcodebuild test -only-testing:JarvisAppTests/CoachHintE2ERenderTests ...
///
/// Output → app Documents/coach-e2e-screen.png. Pull with:
///     xcrun simctl get_app_container booted dev.vasechko.jarvis data
@MainActor
final class CoachHintE2ERenderTests: XCTestCase {

    /// Thread-safe sink for coach frames arriving on the transport's (non-main)
    /// `onWorkoutEnvelope` callback; drained on the MainActor before rendering.
    private final class CoachBox: @unchecked Sendable {
        private let lock = NSLock()
        private var noRef: [String] = []
        private var withRef: [(text: String, slug: String, idx: Int)] = []
        func addNoRef(_ t: String) { lock.lock(); noRef.append(t); lock.unlock() }
        func addRef(_ t: String, _ s: String, _ i: Int) { lock.lock(); withRef.append((t, s, i)); lock.unlock() }
        func drainNoRef() -> [String] { lock.lock(); defer { lock.unlock() }; let x = noRef; noRef = []; return x }
        func drainRef() -> [(text: String, slug: String, idx: Int)] { lock.lock(); defer { lock.unlock() }; let x = withRef; withRef = []; return x }
    }

    private let harness = E2EHarness()
    private var socket: URLSessionWebSocket?

    override func setUp() async throws {
        try await super.setUp()
        try harness.start(scenario: "workout")
        if !E2EHarness.isHarnessReachable() {
            throw XCTSkip("e2e-harness not reachable on ws://127.0.0.1:\(E2EHarness.defaultPort). Start with `E2E_SCENARIO=workout pnpm run e2e:harness`.")
        }
    }

    override func tearDown() async throws {
        socket?.close(); socket = nil
        harness.stop()
        try await super.tearDown()
    }

    private func plan() -> WorkoutPlan {
        WorkoutPlan(
            workoutId: "w1", dayName: "Жим лёжа", week: 2, intensityLabel: "тяжёлая",
            exercises: [
                ExercisePlan(exerciseSlug: "bench-press", targetSets: 4, targetReps: "8",
                             targetRir: 2, restSec: 120, nameRu: "Жим лёжа", weightKgTarget: 80),
                ExercisePlan(exerciseSlug: "incline-db-press", targetSets: 3, targetReps: "10",
                             targetRir: 2, restSec: 90, nameRu: "Жим гантелей", weightKgTarget: 30),
            ],
            imageManifest: [])
    }

    func testRenderCoachSurfacesFromFakeServer() async throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        // Local stage: a coordinator with one *user-logged* set (5 vs target "8"
        // → repsUnder deviation). Logging a set is a genuine user action; the
        // coach reply that anchors on it comes from the server below.
        let queue = SetLogQueue(writer: dbq)
        let coord = WorkoutCoordinator(plan: plan(), queue: queue)
        coord.logSet(reps: 5, weight: 80, repsInReserve: 2)

        // Real transport → fake server. Its onWorkoutEnvelope fires for every
        // inbound workout-family frame; we bank the coach texts thread-safely.
        let serverURL = URL(string: "ws://127.0.0.1:\(E2EHarness.defaultPort)")!
        let socket = URLSessionWebSocket(url: serverURL)
        self.socket = socket
        let transport = TransportV2(store: store, socket: socket, token: E2EHarness.defaultToken)
        let box = CoachBox()
        await transport.setOnWorkoutEnvelope { env in
            guard case .coachMessage(let p) = env.payload else { return }
            if let r = p.set_ref { box.addRef(p.text, r.exercise_slug, r.set_idx) }
            else { box.addNoRef(p.text) }
        }

        // Mount the runner in a real on-screen window BEFORE connecting, so the
        // Path A `.onReceive(coachMessages)` subscription is live when the
        // server's coach frame is forwarded into the subject.
        let coachSubject = PassthroughSubject<String, Never>()
        let hosting = UIHostingController(rootView:
            WorkoutView(
                coordinator: coord,
                imageResolver: { _ in nil },
                coachMessages: coachSubject.eraseToAnyPublisher(),
                onClose: { _ in }, onSwap: { _ in })
                .frame(width: 390, height: 844)
                .environment(\.colorScheme, .dark)
        )
        // A bare UIWindow renders to nothing (drawHierarchy → blank) unless it's
        // attached to the test host app's live UIWindowScene.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        window.setNeedsLayout(); window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)   // let SwiftUI mount + subscribe

        await connect(transport)
        try await waitForAuthed(transport: transport, timeout: 3.0)

        // Poll the box until the server has delivered both coach frames.
        var noRefs: [String] = []
        var refs: [(text: String, slug: String, idx: Int)] = []
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && (noRefs.isEmpty || refs.isEmpty) {
            noRefs += box.drainNoRef()
            refs += box.drainRef()
            if noRefs.isEmpty || refs.isEmpty { try await Task.sleep(nanoseconds: 80_000_000) }
        }
        XCTAssertFalse(noRefs.isEmpty, "fake server never delivered a coach_message without set_ref")
        XCTAssertFalse(refs.isEmpty, "fake server never delivered a coach_message with set_ref")

        // Apply exactly as the app does: set_ref → attachCoachHint (Path B chip),
        // no set_ref → the coach-line publisher (Path A panel row).
        for r in refs { coord.attachCoachHint(exerciseSlug: r.slug, setIdx: r.idx, text: r.text) }
        for t in noRefs { coachSubject.send(t) }

        // Let onReceive + the 0.25s coach-line animation settle, then capture a
        // real UIKit render pass (steppers included).
        try await Task.sleep(nanoseconds: 800_000_000)
        window.setNeedsLayout(); window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let png = image.pngData() else { return XCTFail("no PNG from render pass") }
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("coach-e2e-screen.png")
        try png.write(to: url)
        print("WROTE \(url.path) (\(png.count) bytes)")
    }

    // MARK: - Helpers

    private func connect(_ transport: TransportV2) async {
        do { try await transport.connect() }
        catch { XCTFail("transport.connect failed: \(error)") }
    }

    private func waitForAuthed(transport: TransportV2, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await transport.state == .authed { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("transport did not reach .authed within \(timeout)s; final=\(await transport.state)")
    }
}
