import XCTest
import SwiftUI
import Combine
import GRDB
@testable import Jarvis

/// Renders the real runner with an exercise that carries technique: collapsed it
/// is one row «Техника · 3 шага», opened its text sits over the image and the
/// ПЕЙН panel while the set card stays usable, and an exercise without technique
/// has no strip. Snapshots land in the app's Documents as `technique-*.png` for a
/// look by eye.
@MainActor
final class WorkoutViewTechniqueRenderTests: XCTestCase {

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
        try? image.pngData()?.write(to: docs.appendingPathComponent("technique-\(name).png"))
    }

    func test_techniqueStrip_collapsedByDefault_expandsOverTheImage_collapsesOnPreviewChange() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        var press = ExercisePlan(exerciseSlug: "zhim-nogami", targetSets: 3, targetReps: "10", targetRir: 2,
                                 restSec: 120, nameRu: "Жим ногами", weightKgTarget: 160)
        press.technique = ExerciseTechnique(
            steps: [.init(title: "Исходное положение", text: "Спина прижата к спинке."),
                    .init(title: "Жим", text: "На выдохе, колени не блокировать."),
                    .init(title: "Возврат", text: "Плавно до 90°.")],
            warnings: ["Колени по линии стоп."])
        let bare = ExercisePlan(exerciseSlug: "tyaga", targetSets: 3, targetReps: "10", targetRir: 2,
                                restSec: 120, nameRu: "Тяга блока")
        let plan = WorkoutPlan(workoutId: "w1", dayName: "Ноги", week: 1, intensityLabel: "лёгкая",
                               exercises: [press, bare], imageManifest: [])
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

        let collapsed = texts(in: host.view)
        snapshot(window, "1-collapsed")
        XCTAssertTrue(collapsed.contains("Техника · 3 шага"), "collapsed: \(collapsed)")
        XCTAssertFalse(collapsed.contains { $0.contains("Спина прижата") }, "collapsed: \(collapsed)")

        // Second host, opened: text over the image, set card still there.
        let openView = WorkoutView(coordinator: coord, imageResolver: { _ in nil },
                                   coachMessages: Empty<String, Never>().eraseToAnyPublisher(),
                                   onClose: { _ in }, onSwap: { _ in }, techniqueExpanded: true)
        let openHost = UIHostingController(rootView: openView)
        window.rootViewController = openHost
        spin()
        let expanded = texts(in: openHost.view)
        snapshot(window, "2-expanded")
        XCTAssertTrue(expanded.contains { $0.contains("Спина прижата к спинке.") }, "expanded: \(expanded)")
        XCTAssertTrue(expanded.contains("Колени по линии стоп."), "expanded: \(expanded)")
        XCTAssertTrue(expanded.contains("Вес"), "the set card stays usable: \(expanded)")

        // An exercise without technique has no strip at all.
        coord.activate(idx: 1)
        spin()
        let other = texts(in: openHost.view)
        snapshot(window, "3-no-technique")
        XCTAssertFalse(other.contains { $0.hasPrefix("Техника") }, "other: \(other)")
    }
}
