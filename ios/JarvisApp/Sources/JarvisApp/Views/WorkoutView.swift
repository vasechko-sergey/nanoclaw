import SwiftUI
import Combine

/// Live workout runner. Flexible ~50/50 split: large image hero on top,
/// controls below (logged chips + focus set card + icon toolbar). Rest timer
/// ring as an overlay; Payne's coach line sits inside the ПЕЙН panel.
struct WorkoutView: View {
    @StateObject var coordinator: WorkoutCoordinator
    @StateObject var restTimer = RestTimer()
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

    @State private var showAbortConfirm = false
    @State private var showFinish = false
    /// Payne's latest coach line (no `set_ref`). Persists until the next message
    /// replaces it; rendered as a second row inside the ПЕЙН panel.
    @State private var coachHint: String? = nil
    /// Exercise currently being looked at (swipe/chevrons). May differ from the
    /// active exercise (`coordinator.currentExerciseIdx`) while browsing.
    @State private var previewIdx: Int = 0

    private var isLastExercise: Bool {
        coordinator.currentExerciseIdx >= coordinator.totalExercises - 1
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            content
            RestTimerOverlay(timer: restTimer, nextHint: restHint)
                .zIndex(3)
        }
        .preferredColorScheme(.dark)
        .alert("Прервать тренировку?", isPresented: $showAbortConfirm) {
            Button("Прервать", role: .destructive) {
                coordinator.abort()
                restTimer.skip()
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
                setCount: coordinator.logged.reduce(0) { $0 + $1.sets.count },
                onCancel: { showFinish = false },
                onDone: { feeling, label in
                    let session = coordinator.complete(sessionFeeling: feeling, sessionFeelingLabel: label)
                    restTimer.skip()
                    showFinish = false
                    onClose(session)
                }
            )
        }
        .onAppear { previewIdx = coordinator.currentExerciseIdx; onAppearPrefetch() }
        .onChange(of: coordinator.currentExerciseIdx) { _, new in previewIdx = new }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restTimer.refresh() }
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

                if previewIdx == coordinator.currentExerciseIdx {
                    if coordinator.currentExercise.isDuration {
                        DurationCard(exercise: coordinator.currentExercise, onDone: advance)
                            .padding(.horizontal, 16).padding(.top, 12)
                    } else {
                        VStack(spacing: 10) {
                            LoggedSetChips(
                                logged: coordinator.loggedForCurrentExercise,
                                currentSetIdx: coordinator.currentSetIdx,
                                targetSets: coordinator.currentExercise.targetSets)
                            FocusSetCard(coordinator: coordinator, restTimer: restTimer)
                        }
                        .padding(.horizontal, 16).padding(.top, 10)
                    }
                } else {
                    startExerciseButton
                }

                Spacer(minLength: 0)
                toolbar
            }
        }
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
            Text(WorkoutRunnerLogic.exerciseCounter(activeIdx: coordinator.currentExerciseIdx, total: coordinator.totalExercises))
                .font(.caption).monospacedDigit().foregroundStyle(.white)
            Button(action: advance) {
                Text(isLastExercise ? "Финиш" : "Дальше →").font(.subheadline).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.background)
    }

    private var progressSegments: [WorkoutRunnerLogic.ProgressSegment] {
        WorkoutRunnerLogic.progressSegments(
            total: coordinator.totalExercises,
            activeIdx: coordinator.currentExerciseIdx,
            previewIdx: previewIdx)
    }

    @ViewBuilder
    private func segmentView(_ seg: WorkoutRunnerLogic.ProgressSegment) -> some View {
        let fill: Color = {
            switch seg.kind {
            case .done: return Theme.accent
            case .active: return Color(red: 0.5, green: 0.89, blue: 0.92)
            case .upcoming: return Color.white.opacity(0.2)
            }
        }()
        Capsule().fill(fill).frame(height: 5)
            .overlay(previewRing(seg.kind == .active || seg.isPreview))
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
        return coordinator.logged[idx].sets.isEmpty ? "ещё не начато" : "пройдено"
    }

    /// Rest-overlay hint: the next unfinished set, scanning from the active
    /// exercise across the whole plan (surfaces skipped-then-returned exercises).
    private var restHint: String {
        WorkoutRunnerLogic.restHint(
            logged: coordinator.logged,
            exercises: coordinator.plan.exercises,
            activeIdx: coordinator.currentExerciseIdx
        )
    }

    /// "Дальше →": advance to the next exercise, or open the finish sheet if last.
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
    /// Surface a coach_message as the persistent coach line in the ПЕЙН panel.
    /// It stays put until the next coach_message replaces it (no auto-dismiss) —
    /// so a hint that arrived mid-set is still readable when the user looks up.
    func surfaceCoachMessage(_ text: String) {
        withAnimation(.easeOut(duration: 0.25)) { coachHint = text }
    }
}
