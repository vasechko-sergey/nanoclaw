import XCTest
import SwiftUI
import Combine
import GRDB
@testable import Jarvis

/// Renders the real runner and reads the rest screen's «Дальше:» line and the
/// header's «Дальше →» after leaving the plan order. 2026-10-19, Верх А: Хаммер,
/// then the vertical pull ahead of Смит and the row (machines busy) — every rest
/// on the pull said «Дальше: Смит», and «Дальше →» went by number regardless.
@MainActor
final class WorkoutViewRestHintRenderTests: XCTestCase {

    private func texts(in root: NSObject) -> [String] {
        var out: [String] = []
        func walk(_ o: NSObject, depth: Int) {
            guard depth < 40 else { return }
            if let l = o.accessibilityLabel, !l.isEmpty { out.append(l) }
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

    private func element(in root: NSObject, label: String) -> NSObject? {
        if root.accessibilityLabel == label { return root }
        if let els = root.accessibilityElements as? [NSObject] {
            for e in els { if let hit = element(in: e, label: label) { return hit } }
        } else {
            let n = root.accessibilityElementCount()
            if n > 0 && n != NSNotFound {
                for i in 0..<n {
                    if let e = root.accessibilityElement(at: i) as? NSObject, let hit = element(in: e, label: label) { return hit }
                }
            }
        }
        if let v = root as? UIView { for s in v.subviews { if let hit = element(in: s, label: label) { return hit } } }
        return nil
    }

    private func spin(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func snapshot(_ window: UIWindow, _ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? image.pngData()?.write(to: docs.appendingPathComponent("rest-\(name).png"))
    }

    private func ex(_ slug: String, _ name: String, sets: Int) -> ExercisePlan {
        ExercisePlan(exerciseSlug: slug, targetSets: sets, targetReps: "10-12", targetRir: 2,
                     restSec: 90, nameRu: name, weightKgTarget: 40)
    }

    func test_outOfOrder_restSaysPlanNext_andHeaderFollowsIt() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "Верх А", week: 2, intensityLabel: "лёгкая",
            exercises: [
                ex("hammer", "Жим в Хаммере", sets: 3),
                ex("smith", "Жим в Смите", sets: 1),
                ex("row", "Тяга горизонтального блока", sets: 2),
                ex("pulldown", "Тяга вертикального блока", sets: 1),
                ex("pushdown", "Разгибание в блоке", sets: 2),
            ],
            imageManifest: []
        )
        let coord = WorkoutCoordinator(plan: plan, queue: SetLogQueue(writer: dbq))
        let rest = RestTimer()
        let view = WorkoutView(
            coordinator: coord,
            restTimer: rest,
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

        for _ in 0..<3 { coord.logSet(reps: 11, weight: 62.5, repsInReserve: 1) }
        coord.activate(idx: 3)                       // pull-down ahead of Смит and the row
        coord.logSet(reps: 12, weight: 62.5, repsInReserve: 2)
        rest.start(planned: 90, lastRepsInReserve: 2)
        spin()

        let resting = texts(in: host.view)
        snapshot(window, "1-pulldown")
        XCTAssertTrue(resting.contains("Дальше: Разгибание в блоке — подход 1"), "rest: \(resting)")
        XCTAssertTrue(resting.contains("пропущено: Жим в Смите, Тяга горизонтального блока"), "rest: \(resting)")

        rest.skip()
        spin()
        let next = try XCTUnwrap(element(in: host.view, label: "Дальше →"))
        XCTAssertTrue(next.accessibilityActivate())
        spin()
        XCTAssertEqual(coord.currentExerciseIdx, 4, "«Дальше →» goes where the rest screen said")

        // Last in the plan, skipped ones behind: «Дальше →» leads back to them.
        for _ in 0..<2 { coord.logSet(reps: 12, weight: 65, repsInReserve: 2) }
        spin()
        let back = try XCTUnwrap(element(in: host.view, label: "Дальше →"), "\(texts(in: host.view))")
        XCTAssertTrue(back.accessibilityActivate())
        spin()
        XCTAssertEqual(coord.currentExerciseIdx, 1)

        // Smith, then the row: nothing left — the header offers «Финиш».
        coord.logSet(reps: 11, weight: 20, repsInReserve: 2)
        XCTAssertTrue(try XCTUnwrap(element(in: host.view, label: "Дальше →")).accessibilityActivate())
        spin()
        XCTAssertEqual(coord.currentExerciseIdx, 2)
        for _ in 0..<2 { coord.logSet(reps: 11, weight: 27, repsInReserve: 2) }
        spin()
        let end = texts(in: host.view)
        snapshot(window, "2-all-done")
        XCTAssertTrue(end.contains("Финиш"), "end: \(end)")
        XCTAssertFalse(end.contains("Дальше →"), "end: \(end)")
    }
}
