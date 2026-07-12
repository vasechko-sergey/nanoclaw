import XCTest
import SwiftUI
import GRDB
import Combine
@testable import Jarvis

/// Snapshot-render harness (NOT an assertion test): rasterizes the real
/// coach-hint surfaces with `ImageRenderer` and writes PNGs into the host app's
/// Documents container so they can be pulled off the simulator and eyeballed.
///
///   xcrun simctl get_app_container booted dev.vasechko.jarvis data
///   → <container>/Documents/coach-*.png
///
/// Renders three views:
///   coach-panel.png   RecommendationPanel WITH a coachHint  (Path A — no set_ref)
///   coach-chips.png   LoggedSetChips with a hinted+deviated set (Path B — set_ref)
///   coach-screen.png  the whole WorkoutView with that set logged (full runner)
@MainActor
final class CoachHintRenderTests: XCTestCase {

    private func makeQueue() throws -> SetLogQueue {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return SetLogQueue(writer: dbq)
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

    private let coachLine =
        "Держи локти под 45°, не разводи в стороны — плечо целее будет. Темп 2-0-1, без отбива от груди."

    /// Render a SwiftUI view to a PNG at iPhone-logical size on the app's dark bg.
    private func save(_ name: String, width: CGFloat = 390, height: CGFloat = 844,
                      @ViewBuilder _ view: () -> some View) throws {
        let content = ZStack {
            Theme.background
            view()
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let png = renderer.uiImage?.pngData() else {
            return XCTFail("ImageRenderer produced no image for \(name)")
        }
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        try png.write(to: url)
        print("WROTE \(url.path) (\(png.count) bytes)")
    }

    func test_render_pathA_panelCoachLine() throws {
        try save("coach-panel.png", height: 220) {
            VStack {
                Spacer()
                RecommendationPanel(exercise: plan().exercises[0], coachHint: coachLine)
                Spacer()
            }
        }
    }

    func test_render_pathB_chipBadge() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: plan(), queue: queue)
        coord.logSet(reps: 5, weight: 80, repsInReserve: 2)        // 5 vs "8" → repsUnder
        coord.attachCoachHint(exerciseSlug: "bench-press", setIdx: 0,
                              text: "Не добил до восьми — вес норм, добавь паузу внизу.")
        try save("coach-chips.png", height: 120) {
            VStack {
                Spacer()
                LoggedSetChips(logged: coord.loggedForCurrentExercise,
                               currentSetIdx: coord.currentSetIdx,
                               targetSets: coord.currentExercise.targetSets)
                    .padding(.horizontal, 16)
                Spacer()
            }
        }
    }

    func test_render_fullRunner() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: plan(), queue: queue)
        coord.logSet(reps: 5, weight: 80, repsInReserve: 2)
        coord.attachCoachHint(exerciseSlug: "bench-press", setIdx: 0,
                              text: "Не добил до восьми — вес норм, добавь паузу внизу.")
        try save("coach-screen.png") {
            WorkoutView(
                coordinator: coord,
                imageResolver: { _ in nil },
                coachMessages: Empty<String, Never>().eraseToAnyPublisher(),
                onClose: { _ in }, onSwap: { _ in })
        }
    }
}
