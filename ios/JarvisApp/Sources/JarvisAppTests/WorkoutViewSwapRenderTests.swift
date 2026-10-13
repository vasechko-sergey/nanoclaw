import XCTest
import SwiftUI
import Combine
import GRDB
@testable import Jarvis

/// Renders the real runner and reads what it says on screen after a swap
/// (accessibility tree of a hosted WorkoutView). 2026-10-13: Payne prescribed
/// 65 кг for the hammer press swapped in, the coordinator's plan held 65 (the
/// set_log deviation carried it), yet the weight wheel stayed on the replaced
/// dumbbells' 20.
@MainActor
final class WorkoutViewSwapRenderTests: XCTestCase {

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

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func test_panelShowsSwappedInExercisesWeight() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "Верх Б", week: 4, intensityLabel: "разгрузочная",
            exercises: [
                ExercisePlan(exerciseSlug: "zhim-ganteley", targetSets: 4, targetReps: "10-12",
                             targetRir: 2, restSec: 120, nameRu: "Жим гантелей лёжа", weightKgTarget: 20),
            ],
            imageManifest: []
        )
        let coord = WorkoutCoordinator(plan: plan, queue: SetLogQueue(writer: dbq))
        let view = WorkoutView(
            coordinator: coord,
            imageResolver: { _ in nil },
            coachMessages: Empty<String, Never>().eraseToAnyPublisher(),
            onClose: { _ in },
            onSwap: { _ in }
        )
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        spin()
        let before = texts(in: host.view)
        XCTAssertTrue(before.contains("20 кг"), "before: \(before)")

        coord.applySwap(originalSlug: "zhim-ganteley", newSlug: "zhim-hammer",
                        newName: "Жим в хаммере", newWeightTarget: 65)
        spin()
        let after = texts(in: host.view)
        XCTAssertTrue(after.contains("Жим в хаммере"), "after: \(after)")
        XCTAssertTrue(after.contains("65 кг"), "after: \(after)")
        XCTAssertFalse(after.contains("20 кг"), "after: \(after)")
        // The weight wheel follows too — it re-seeded on the index alone and
        // stayed on the dumbbells' 20 (build 125 fix).
        XCTAssertEqual(wheelValue(after, title: "Вес"), "65", "after: \(after)")
    }

    /// The value the wheel titled `title` exposes ("Вес" → "value:65").
    private func wheelValue(_ texts: [String], title: String) -> String? {
        guard let i = texts.firstIndex(of: title), texts.indices.contains(i + 1),
              texts[i + 1].hasPrefix("value:") else { return nil }
        return String(texts[i + 1].dropFirst("value:".count))
    }
}
