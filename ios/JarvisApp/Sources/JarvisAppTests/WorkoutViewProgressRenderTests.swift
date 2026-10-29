import XCTest
import SwiftUI
import Combine
import GRDB
@testable import Jarvis

/// Renders the real runner with one set of three on the press and reads the
/// header. 2026-10-29: one set of three read as a done exercise. Snapshots land
/// in the app's Documents as `progress-*.png` for a look by eye.
@MainActor
final class WorkoutViewProgressRenderTests: XCTestCase {

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
        try? image.pngData()?.write(to: docs.appendingPathComponent("progress-\(name).png"))
    }

    func test_oneSetOfThree_readsPartial_inCounterAndPreviewTag() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "Верх", week: 1, intensityLabel: "лёгкая",
            exercises: [
                ExercisePlan(exerciseSlug: "zhim", targetSets: 3, targetReps: "8-10", targetRir: 2,
                             restSec: 120, nameRu: "Жим лёжа", weightKgTarget: 60),
                ExercisePlan(exerciseSlug: "tyaga", targetSets: 3, targetReps: "10-12", targetRir: 2,
                             restSec: 120, nameRu: "Тяга блока", weightKgTarget: 50),
            ],
            imageManifest: []
        )
        let coord = WorkoutCoordinator(plan: plan, queue: SetLogQueue(writer: dbq))
        let view = WorkoutView(coordinator: coord, imageResolver: { _ in nil },
                               coachMessages: Empty<String, Never>().eraseToAnyPublisher(),
                               onClose: { _ in }, onSwap: { _ in })
        let host = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        spin()

        coord.logSet(reps: 9, weight: 60, repsInReserve: 2)
        coord.activate(idx: 1)
        spin()
        let t = texts(in: host.view)
        snapshot(window, "1-partial")
        XCTAssertTrue(t.contains("0/2"), "a third of the press is not a done exercise: \(t)")
    }
}
