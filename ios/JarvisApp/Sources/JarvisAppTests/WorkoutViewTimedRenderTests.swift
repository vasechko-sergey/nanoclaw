import XCTest
import SwiftUI
import Combine
import GRDB
@testable import Jarvis

/// Renders the real runner on a mesocycle-3 day — treadmill warmup, then a
/// plank in sets — and reads what is on screen. 2026-10-13: the warmup showed a
/// fixed «5:00» and «Засчитать» recorded nothing; a plank with sets would have
/// got the reps and weight wheels. Snapshots land in the app's Documents as
/// `timed-*.png` for a look by eye.
@MainActor
final class WorkoutViewTimedRenderTests: XCTestCase {

    private func texts(in root: NSObject) -> [String] {
        var out: [String] = []
        func walk(_ o: NSObject, depth: Int) {
            guard depth < 40 else { return }
            if let l = o.accessibilityLabel, !l.isEmpty { out.append(l) }
            if let v = o.accessibilityValue, !v.isEmpty { out.append("value:" + v) }
            if let els = o.accessibilityElements as? [NSObject] {
                for e in els { walk(e, depth: depth + 1) }
            } else {
                let n = o.accessibilityElementCount()
                if n > 0 && n != NSNotFound {
                    for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth: depth + 1) } }
                }
            }
            if let v = o as? UIView { for s in v.subviews { walk(s, depth: depth + 1) } }
        }
        walk(root, depth: 0)
        return out
    }

    private func spin(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func snapshot(_ window: UIWindow, _ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? image.pngData()?.write(to: docs.appendingPathComponent("timed-\(name).png"))
    }

    /// The value of the wheel titled `title`. The column caption carries the same
    /// text, so look for the title that is followed by a value.
    private func wheelValue(_ texts: [String], title: String) -> String? {
        guard let i = texts.indices.dropLast().first(where: { texts[$0] == title && texts[$0 + 1].hasPrefix("value:") })
        else { return nil }
        return String(texts[i + 1].dropFirst("value:".count))
    }

    func test_warmupAndPlank_showTimeWheelsAndStopwatch_notWeight() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "Ноги А", week: 1, intensityLabel: "лёгкая",
            exercises: [
                ExercisePlan(exerciseSlug: "hodba-na-begovoy-dorozhke", targetSets: 0, targetReps: "",
                             targetRir: 0, restSec: 0, nameRu: "Ходьба на беговой дорожке", durationSec: 300),
                ExercisePlan(exerciseSlug: "planka", targetSets: 2, targetReps: "", targetRir: 0,
                             restSec: 60, nameRu: "Планка", durationSec: 120),
                ExercisePlan(exerciseSlug: "zhim-nogami", targetSets: 4, targetReps: "8-10", targetRir: 2,
                             restSec: 180, nameRu: "Жим ногами", weightKgTarget: 235),
            ],
            imageManifest: []
        )
        let coord = WorkoutCoordinator(plan: plan, queue: SetLogQueue(writer: dbq))
        var clock = Date(timeIntervalSince1970: 0)
        let hold = HoldTimer()
        hold.now = { clock }
        let view = WorkoutView(
            coordinator: coord,
            holdTimer: hold,
            imageResolver: { _ in nil },
            coachMessages: Empty<String, Never>().eraseToAnyPublisher(),
            onClose: { _ in },
            onSwap: { _ in }
        )
        let host = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        spin()

        // Warmup: target time on the wheels, «Засчитать», no reserve chip.
        let warm = texts(in: host.view)
        snapshot(window, "1-warmup")
        XCTAssertEqual(wheelValue(warm, title: "Минуты"), "5", "warmup: \(warm)")
        XCTAssertEqual(wheelValue(warm, title: "Секунды"), "00", "warmup: \(warm)")
        XCTAssertTrue(warm.contains { $0.contains("Засчитать 5:00") }, "warmup: \(warm)")
        XCTAssertFalse(warm.contains("Вес"), "warmup: \(warm)")
        XCTAssertFalse(warm.contains("запас 0"), "warmup: \(warm)")

        // Walked longer: the time recorded is what was held.
        coord.logTimedSet(seconds: 420)
        coord.finishExercise(comment: nil)
        spin()

        // Plank: «2×2:00» in the panel, minutes/seconds wheels, no weight.
        let plank = texts(in: host.view)
        snapshot(window, "2-plank")
        XCTAssertTrue(plank.contains("2×2:00"), "plank: \(plank)")
        XCTAssertTrue(plank.contains("отдых 1:00"), "plank: \(plank)")
        XCTAssertEqual(wheelValue(plank, title: "Минуты"), "2", "plank: \(plank)")
        XCTAssertTrue(plank.contains { $0.contains("Записать 2:00") }, "plank: \(plank)")
        XCTAssertFalse(plank.contains("Вес"), "plank: \(plank)")
        XCTAssertFalse(plank.contains("Повторы"), "plank: \(plank)")

        // Holding: the stopwatch replaces the wheels, «Стоп» the buttons.
        hold.start(targetSec: 120)
        clock = clock.addingTimeInterval(72)
        hold.refresh()
        spin()
        let running = texts(in: host.view)
        snapshot(window, "3-plank-running")
        XCTAssertTrue(running.contains("1:12"), "running: \(running)")
        XCTAssertTrue(running.contains("цель 2:00"), "running: \(running)")
        XCTAssertTrue(running.contains { $0.contains("Стоп") }, "running: \(running)")

        // First set logged: the chip reads the time, the wheels start from it.
        hold.reset()
        coord.logTimedSet(seconds: 115)
        spin()
        let second = texts(in: host.view)
        snapshot(window, "4-plank-set2")
        XCTAssertTrue(second.contains { $0.contains("1:55") }, "set 2: \(second)")
        XCTAssertTrue(second.contains("подход 2 из 2"), "set 2: \(second)")
        XCTAssertEqual(coord.logged[0].sets.map(\.durationSec), [420])
    }
}
