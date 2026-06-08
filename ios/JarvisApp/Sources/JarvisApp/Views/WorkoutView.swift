import SwiftUI

/// Top-level workout flow. Owns the Coordinator + RestTimer; renders the
/// exercise card, set list (read-only + active row), bottom bar, and
/// overlays (rest timer, coach banner).
struct WorkoutView: View {
    @StateObject var coordinator: WorkoutCoordinator
    @StateObject var restTimer = RestTimer()

    /// Resolve a slug+sha256 to a local cached image URL. Pass the
    /// ExerciseImageCache from the host (so the same cache is shared with
    /// inbound dispatcher prefetch).
    let imageResolver: (_ slug: String) -> URL?

    /// Called when user taps ✕ (abort) or finishes successfully (complete).
    var onClose: (WorkoutSession?) -> Void

    /// Called when user taps swap on the active exercise.
    var onSwap: (_ exerciseSlug: String) -> Void

    @State private var showAbortConfirm = false
    @State private var showFinishSheet = false
    @State private var finishOverallRir: Int = 2
    @State private var coachBanner: String? = nil

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
            RestTimerOverlay(timer: restTimer)
                .zIndex(3)
        }
        .preferredColorScheme(.dark)
        .alert("Прервать тренировку?",
               isPresented: $showAbortConfirm) {
            Button("Прервать", role: .destructive) {
                coordinator.abort()
                restTimer.skip()
                onClose(nil)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Логи уже записанных подходов сохранятся.")
        }
        .sheet(isPresented: $showFinishSheet) {
            finishSheet
        }
        .accessibilityIdentifier("workout-view")
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            navbar
            progressDots
            ScrollView {
                VStack(spacing: 16) {
                    ExerciseCardView(
                        exercise: coordinator.currentExercise,
                        imageURL: imageResolver(coordinator.currentExercise.exerciseSlug),
                        onSwap: { onSwap(coordinator.currentExercise.exerciseSlug) }
                    )
                    .padding(.horizontal)

                    VStack(spacing: 8) {
                        ForEach(coordinator.loggedForCurrentExercise.indices, id: \.self) { i in
                            LoggedSetRow(idx: i, set: coordinator.loggedForCurrentExercise[i])
                                .padding(.horizontal)
                        }
                        if !coordinator.isFinished {
                            ActiveSetRowView(coordinator: coordinator, restTimer: restTimer)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.vertical, 12)
            }
            bottomBar
        }
    }

    private var navbar: some View {
        HStack {
            Button { showAbortConfirm = true } label: {
                Image(systemName: "xmark")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(coordinator.plan.dayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("нед. \(coordinator.plan.week) · \(coordinator.plan.intensityLabel)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            // Balance: invisible spacer with same width as ✕ button.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<coordinator.totalExercises, id: \.self) { i in
                Circle()
                    .fill(dotColor(at: i))
                    .frame(width: 8, height: 8)
            }
            Text("\(coordinator.currentExerciseIdx + 1) из \(coordinator.totalExercises)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)
        }
        .padding(.bottom, 12)
    }

    private func dotColor(at idx: Int) -> Color {
        if idx < coordinator.currentExerciseIdx { return Theme.accent.opacity(0.7) }
        if idx == coordinator.currentExerciseIdx { return Theme.accent }
        return Theme.accent.opacity(0.2)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                coordinator.finishExercise(comment: nil)
            } label: {
                Text("закончить упражнение")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                    .foregroundStyle(Theme.accent)
            }
            .frame(minHeight: 44)
            .disabled(coordinator.isFinished)
            Spacer()
            Button {
                showFinishSheet = true
            } label: {
                Text("Финиш")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.accent.opacity(coordinator.readyToComplete ? 0.85 : 0.25)))
                    .foregroundStyle(.white)
            }
            .frame(minHeight: 44)
            .disabled(coordinator.isFinished)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.accent.opacity(0.1)).frame(height: 0.5)
        }
    }

    private var finishSheet: some View {
        VStack(spacing: 24) {
            Text("Как тренировка?")
                .font(.title3.weight(.medium))
            VStack(alignment: .leading, spacing: 6) {
                Text("Общее ощущение, запас по тренировке: \(finishOverallRir) повторов")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Stepper("\(finishOverallRir)", value: $finishOverallRir, in: 0...10)
                    .labelsHidden()
            }
            HStack(spacing: 12) {
                Button("Отмена") { showFinishSheet = false }
                    .frame(maxWidth: .infinity, minHeight: 44)
                Button {
                    let session = coordinator.complete(perceivedOverallRir: finishOverallRir)
                    restTimer.skip()
                    showFinishSheet = false
                    onClose(session)
                } label: {
                    Text("Готово")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding()
        .presentationDetents([.medium])
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
