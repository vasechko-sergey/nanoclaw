import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Live workout runner. Flexible ~50/50 split: large image hero on top,
/// controls below (logged chips + focus set card + icon toolbar). Rest timer
/// ring as an overlay; Payne's coach line sits inside the ПЕЙН panel.
struct WorkoutView: View {
    @StateObject var coordinator: WorkoutCoordinator
    @StateObject var restTimer = RestTimer()
    /// Stopwatch for timed sets (plank, warmup). Lives here, not in the card, so
    /// it survives the card's re-creation and drives the full-screen
    /// `HoldTimerOverlay` (which blocks swiping while a hold runs).
    @StateObject var holdTimer = HoldTimer()
    @Environment(\.scenePhase) private var scenePhase

    /// Resolve a slug to a local cached image URL (shared with inbound prefetch).
    let imageResolver: (_ slug: String) -> URL?

    /// Stream of coach_message texts WITHOUT `set_ref` — surfaced as the coach
    /// line inside the ПЕЙН panel via `surfaceCoachMessage`. ChatView filters
    /// `workoutBus.events` to `.coachMessage(_, _, nil)` and passes the mapped
    /// publisher in. The line persists until the next message replaces it.
    ///
    /// Coach messages WITH `set_ref` (deviation replies) are handled in ChatView
    /// where the `WorkoutCoordinator` reference lives — they anchor on a chip.
    let coachMessages: AnyPublisher<String, Never>

    /// Called when user taps ✕ (abort) or finishes successfully (complete).
    var onClose: (WorkoutSession?) -> Void

    /// Called when user taps swap on the current exercise.
    var onSwap: (_ exerciseSlug: String) -> Void

    /// Fired on appear so the host can prefetch the plan's images.
    var onAppearPrefetch: () -> Void = {}

    /// Opens the technique text on appear. Taps can't be driven from XCTest, so
    /// the render test seeds the expanded state through this; the app never sets it.
    var techniqueExpanded: Bool = false

    @State private var showAbortConfirm = false
    @State private var showFinish = false
    /// Payne's latest coach line (no `set_ref`). Persists until the next message
    /// replaces it; rendered as a second row inside the ПЕЙН panel.
    @State private var coachHint: String? = nil
    /// Exercise currently being looked at (swipe/chevrons). May differ from the
    /// active exercise (`coordinator.currentExerciseIdx`) while browsing.
    @State private var previewIdx: Int = 0
    /// The technique text is open over the image and the ПЕЙН panel.
    @State private var techniqueOpen = false

    /// Slug of the exercise being looked at. A swap replaces it in place — the
    /// preview index stays, this changes — so the technique block keys on both.
    private var previewSlug: String? {
        coordinator.plan.exercises.indices.contains(previewIdx)
            ? coordinator.plan.exercises[previewIdx].exerciseSlug : nil
    }

    /// Nothing left anywhere: the header button reads «Финиш».
    private var isLastExercise: Bool {
        WorkoutRunnerLogic.nextExerciseIdx(
            logged: coordinator.logged,
            exercises: coordinator.plan.exercises,
            activeIdx: coordinator.currentExerciseIdx
        ) == nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            content
            RestTimerOverlay(timer: restTimer, nextHint: restHint, skippedHint: skippedHint)
                .zIndex(3)
            HoldTimerOverlay(timer: holdTimer, title: holdTitle) {
                Theme.hapticSend()
                holdTimer.stop()
            }
            .zIndex(4)
        }
        .preferredColorScheme(.dark)
        .alert("Прервать тренировку?", isPresented: $showAbortConfirm) {
            Button("Прервать", role: .destructive) {
                coordinator.abort()
                restTimer.skip()
                holdTimer.reset()
                onClose(nil)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Логи уже записанных подходов сохранятся.")
        }
        .fullScreenCover(isPresented: $showFinish) {
            WorkoutFinishView(
                dayName: coordinator.plan.dayName,
                exerciseCount: coordinator.totalExercises,
                setCount: coordinator.totalLoggedSets,
                onCancel: { showFinish = false },
                onDone: { feeling, label in
                    let session = coordinator.complete(sessionFeeling: feeling, sessionFeelingLabel: label)
                    restTimer.skip()
                    holdTimer.reset()
                    showFinish = false
                    onClose(session)
                }
            )
        }
        .onAppear {
            previewIdx = coordinator.currentExerciseIdx
            techniqueOpen = techniqueExpanded
            onAppearPrefetch()
        }
        .onChange(of: coordinator.currentExerciseIdx) { _, new in previewIdx = new }
        // The technique text belongs to the exercise being looked at: it starts
        // collapsed whenever that changes — another one, or a swap in place.
        .onChange(of: previewIdx) { _, _ in techniqueOpen = false }
        .onChange(of: previewSlug) { _, _ in techniqueOpen = false }
        // A hold belongs to the exercise it was started on.
        .onChange(of: coordinator.currentExerciseKey) { _, _ in holdTimer.reset() }
        .onChange(of: holdTimer.running) { _, _ in keepScreenAwake() }
        .onChange(of: restTimer.running) { _, _ in keepScreenAwake() }
        .onDisappear { setIdleTimerDisabled(false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                restTimer.refresh()
                holdTimer.refresh()
                // Blend 1+3: the phone was likely lying down during rest, so the
                // card alone can go unseen. Re-announce an unread deviation hint
                // with a haptic the moment the user picks the phone back up.
                if coordinator.activeDeviationHint != nil {
                    #if canImport(UIKit)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    #endif
                }
            }
        }
        // Coach message WITHOUT set_ref → 4-sec top banner. With the runner open,
        // this is the ONLY surface for coach text that isn't anchored on a set
        // (e.g. abort ack "Принял…", global tempo hint, warmup nudge).
        .onReceive(coachMessages) { text in
            surfaceCoachMessage(text)
        }
        .accessibilityIdentifier("workout-view")
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                pinnedHeader

                let preview = coordinator.plan.exercises[previewIdx]
                if let technique = preview.technique {
                    TechniqueRow(technique: technique, expanded: $techniqueOpen)
                }

                // Image + ПЕЙН panel: the technique text opens over exactly this
                // area, so the set card below keeps its place.
                VStack(spacing: 0) {
                    ExerciseBannerView(
                        exercise: preview,
                        imageURL: imageResolver(preview.exerciseSlug),
                        stateTag: stateTag(for: previewIdx),
                        canPrev: previewIdx > 0,
                        canNext: previewIdx < coordinator.totalExercises - 1,
                        onPreview: movePreview
                    )
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: geo.size.width * 9.0 / 16.0)
                    .clipped()

                    RecommendationPanel(exercise: preview, coachHint: coachHint)
                }
                .overlay(alignment: .top) {
                    if techniqueOpen, let technique = preview.technique {
                        TechniqueText(technique: technique)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if previewIdx == coordinator.currentExerciseIdx {
                    if coordinator.currentExercise.isTimed {
                        VStack(spacing: 10) {
                            loggedChips
                            TimedSetCard(coordinator: coordinator, holdTimer: holdTimer,
                                         restTimer: restTimer, onWarmupDone: advance)
                        }
                        .padding(.horizontal, 16).padding(.top, 10)
                    } else {
                        VStack(spacing: 10) {
                            loggedChips
                            // Deviation hint (coach_message WITH set_ref) lands here,
                            // right above the input, so it's read before the next set.
                            if let hint = coordinator.activeDeviationHint {
                                DeviationHintCard(text: hint) { coordinator.dismissDeviationHint() }
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            FocusSetCard(coordinator: coordinator, restTimer: restTimer)
                        }
                        .padding(.horizontal, 16).padding(.top, 10)
                        .animation(.easeOut(duration: 0.25), value: coordinator.activeDeviationHint)
                    }
                } else {
                    startExerciseButton
                }

                Spacer(minLength: 0)
                toolbar
            }
        }
    }

    private var loggedChips: some View {
        LoggedSetChips(
            logged: coordinator.loggedForCurrentExercise,
            currentSetIdx: coordinator.currentSetIdx,
            targetSets: coordinator.currentExercise.targetSets,
            onDeleteSet: { setIdx in
                coordinator.deleteSet(exerciseIdx: coordinator.currentExerciseIdx, setIdx: setIdx)
            },
            onEditSet: { setIdx, reps, weight, rir in
                coordinator.editSet(exerciseIdx: coordinator.currentExerciseIdx,
                                    setIdx: setIdx, reps: reps, weight: weight, repsInReserve: rir)
            },
            onEditDuration: { setIdx, seconds in
                coordinator.editTimedSet(exerciseIdx: coordinator.currentExerciseIdx,
                                         setIdx: setIdx, seconds: seconds)
            })
    }

    private var pinnedHeader: some View {
        HStack(spacing: 12) {
            Button { showAbortConfirm = true } label: {
                Image(systemName: "xmark").font(.body).foregroundStyle(.white).frame(width: 36, height: 36)
            }
            HStack(spacing: 3) {
                ForEach(Array(progressSegments.enumerated()), id: \.offset) { _, seg in
                    segmentView(seg)
                }
            }
            Text(WorkoutRunnerLogic.exerciseCounter(done: progressSegments.filter { $0.kind == .done }.count, total: coordinator.totalExercises))
                .font(.caption).monospacedDigit().foregroundStyle(.white)
            Button(action: advance) {
                Text(isLastExercise ? "Финиш" : "Дальше →").font(.subheadline).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.background)
    }

    /// «ПЛАНКА · ПОДХОД 1» over the hold ring — the active exercise, whatever is previewed.
    private var holdTitle: String {
        WorkoutRunnerLogic.holdTitle(
            name: coordinator.currentExercise.displayName,
            isTimedSets: coordinator.currentExercise.isTimedSets,
            setIdx: coordinator.currentSetIdx)
    }

    private var progressSegments: [WorkoutRunnerLogic.ProgressSegment] {
        WorkoutRunnerLogic.progressSegments(
            sets: coordinator.logged.map { $0.sets.count },
            targetSets: coordinator.plan.exercises.map { $0.targetSets },
            isDuration: coordinator.plan.exercises.map { $0.isDuration },
            activeIdx: coordinator.currentExerciseIdx,
            previewIdx: previewIdx)
    }

    @ViewBuilder
    private func segmentView(_ seg: WorkoutRunnerLogic.ProgressSegment) -> some View {
        let track = Color.white.opacity(0.2)
        Group {
            switch seg.kind {
            case .done: Capsule().fill(Theme.accent)
            case .active: Capsule().fill(Color(red: 0.5, green: 0.89, blue: 0.92))
            case .skipped: Capsule().fill(Color.clear)   // hollow — copper ring carries "passed, not done"
            case .upcoming: Capsule().fill(track)
            case .partial:
                Capsule().fill(track).overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Theme.accent).frame(width: g.size.width * seg.fill)
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 5)
        .overlay(previewRing(seg.kind == .active || seg.isPreview || seg.kind == .skipped || seg.kind == .partial))
    }

    private func previewRing(_ on: Bool) -> some View {
        Capsule().stroke(Color(red: 0.78, green: 0.57, blue: 0.35), lineWidth: on ? 1.5 : 0)
    }

    private var startExerciseButton: some View {
        Button {
            coordinator.activate(idx: previewIdx)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text("Начать это упражнение").font(.body.weight(.medium))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().stroke(Theme.accent, lineWidth: 1).background(Capsule().fill(Theme.accent.opacity(0.16))))
        }
        .padding(.horizontal, 16).padding(.top, 16)
    }

    private func movePreview(_ delta: Int) {
        let next = previewIdx + delta
        guard coordinator.plan.exercises.indices.contains(next) else { return }
        previewIdx = next
    }

    private func stateTag(for idx: Int) -> String {
        if idx == coordinator.currentExerciseIdx {
            return WorkoutRunnerLogic.setLabel(
                currentSetIdx: coordinator.currentSetIdx,
                targetSets: coordinator.currentExercise.targetSets) ?? ""
        }
        return WorkoutRunnerLogic.previewStateTag(sets: coordinator.logged[idx].sets.count,
                                                  targetSets: coordinator.plan.exercises[idx].targetSets)
    }

    /// Rest-overlay hint: the active exercise's next set, else where «Дальше →»
    /// leads — next in plan order, skipped ones once nothing is left ahead.
    private var restHint: String {
        WorkoutRunnerLogic.restHint(
            logged: coordinator.logged,
            exercises: coordinator.plan.exercises,
            activeIdx: coordinator.currentExerciseIdx
        )
    }

    /// «пропущено: …» under the rest hint.
    private var skippedHint: String? {
        WorkoutRunnerLogic.skippedHint(
            logged: coordinator.logged,
            exercises: coordinator.plan.exercises,
            activeIdx: coordinator.currentExerciseIdx
        )
    }

    /// "Дальше →": go where the rest hint points, or open the finish sheet if
    /// nothing is left.
    private func advance() {
        if isLastExercise {
            showFinish = true
        } else {
            coordinator.finishExercise(comment: nil)
        }
    }

    private var toolbar: some View {
        HStack {
            toolbarItem("arrow.2.squarepath", "заменить") {
                onSwap(coordinator.currentExercise.exerciseSlug)
            }
            Spacer()
            toolbarItem("timer", "отдых") {
                restTimer.start(planned: coordinator.currentExercise.restSec,
                                lastRepsInReserve: coordinator.currentExercise.targetRir)
            }
            Spacer()
            toolbarItem("flag", "финиш", tint: Theme.accent) {
                showFinish = true
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(Theme.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.accent.opacity(0.1)).frame(height: 0.5)
        }
    }

    private func toolbarItem(_ sys: String, _ label: String, tint: Color = .white.opacity(0.55), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: sys).font(.system(size: 19))
                Text(label).font(.caption2)
            }
            .foregroundStyle(tint)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

}

extension WorkoutView {
    /// The phone lies on the floor during a plank and on the bench during rest:
    /// no auto-lock while either timer runs, normal locking otherwise.
    func keepScreenAwake() {
        setIdleTimerDisabled(holdTimer.running || restTimer.running)
    }

    func setIdleTimerDisabled(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    /// Surface a coach_message as the persistent coach line in the ПЕЙН panel.
    /// It stays put until the next coach_message replaces it (no auto-dismiss) —
    /// so a hint that arrived mid-set is still readable when the user looks up.
    func surfaceCoachMessage(_ text: String) {
        withAnimation(.easeOut(duration: 0.25)) { coachHint = text }
    }
}
