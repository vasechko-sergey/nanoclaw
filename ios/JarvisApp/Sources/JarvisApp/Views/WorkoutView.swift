import SwiftUI

/// Live workout runner. Flexible ~50/50 split: large image hero on top,
/// controls below (logged chips + focus set card + icon toolbar). Rest timer
/// ring + coach banner as overlays.
struct WorkoutView: View {
    @StateObject var coordinator: WorkoutCoordinator
    @StateObject var restTimer = RestTimer()

    /// Resolve a slug to a local cached image URL (shared with inbound prefetch).
    let imageResolver: (_ slug: String) -> URL?

    /// Called when user taps ✕ (abort) or finishes successfully (complete).
    var onClose: (WorkoutSession?) -> Void

    /// Called when user taps swap on the current exercise.
    var onSwap: (_ exerciseSlug: String) -> Void

    /// Fired on appear so the host can prefetch the plan's images.
    var onAppearPrefetch: () -> Void = {}

    @State private var showAbortConfirm = false
    @State private var showFinish = false
    @State private var coachBanner: String? = nil

    private var isLastExercise: Bool {
        coordinator.currentExerciseIdx >= coordinator.totalExercises - 1
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            content
            if let banner = coachBanner {
                CoachBannerView(text: banner)
                    .padding(.top, 80)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
            RestTimerOverlay(timer: restTimer, nextHint: "подход \(coordinator.currentSetIdx + 1)")
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
        .onAppear { onAppearPrefetch() }
        .accessibilityIdentifier("workout-view")
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ExerciseBannerView(
                    exercise: coordinator.currentExercise,
                    imageURL: imageResolver(coordinator.currentExercise.exerciseSlug),
                    indexLabel: "\(coordinator.currentExerciseIdx + 1)/\(coordinator.totalExercises)",
                    current: coordinator.currentExerciseIdx,
                    total: coordinator.totalExercises,
                    isLast: isLastExercise,
                    onClose: { showAbortConfirm = true },
                    onAdvance: advance
                )
                .frame(height: geo.size.height * 0.46)

                ScrollView {
                    VStack(spacing: 14) {
                        if coordinator.currentExercise.isDuration {
                            DurationCard(exercise: coordinator.currentExercise, onDone: advance)
                        } else {
                            LoggedSetChips(
                                logged: coordinator.loggedForCurrentExercise,
                                currentSetIdx: coordinator.currentSetIdx,
                                targetSets: coordinator.currentExercise.targetSets
                            )
                            FocusSetCard(coordinator: coordinator, restTimer: restTimer)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                }

                toolbar
            }
        }
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
    /// Surface a coach_message banner; auto-dismiss after 4 sec.
    func surfaceCoachMessage(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { coachBanner = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation(.easeIn(duration: 0.2)) { coachBanner = nil }
        }
    }
}
