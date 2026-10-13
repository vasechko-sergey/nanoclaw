import SwiftUI

/// Logger for an exercise measured in seconds: the warmup walk (no sets) and a
/// plank / isometric hold done in sets. Replaces FocusSetCard when
/// `exercise.isTimed`.
///
/// Idle: minutes / seconds wheels seeded from the last hold on this exercise or
/// Payne's target, plus «Старт» and «Записать M:SS». Running: the stopwatch in
/// the wheels' place and «Стоп», which drops the held time into the wheels to
/// be corrected or recorded. The warmup records with «Засчитать» and moves on.
struct TimedSetCard: View {
    @ObservedObject var coordinator: WorkoutCoordinator
    @ObservedObject var holdTimer: HoldTimer
    @ObservedObject var restTimer: RestTimer
    /// Warmup only: leave the exercise once its time is recorded.
    var onWarmupDone: () -> Void

    @State private var minutes = 1
    @State private var seconds = 0

    private var exercise: ExercisePlan { coordinator.currentExercise }
    private var chosen: Int { minutes * 60 + seconds }
    private var target: Int { exercise.durationSec ?? 0 }

    var body: some View {
        VStack(spacing: 10) {
            if holdTimer.running {
                stopwatch
            } else {
                HoldWheels(minutes: $minutes, seconds: $seconds)
            }
            if holdTimer.running {
                Button(action: stop) {
                    label("Стоп", icon: "stop.fill")
                        .foregroundStyle(.white)
                        .background(Capsule().fill(Theme.accent))
                }
            } else {
                HStack(spacing: 10) {
                    Button(action: start) {
                        label("Старт", icon: "play.fill")
                            .foregroundStyle(Theme.accent)
                            .background(Capsule().fill(Theme.surface))
                            .overlay(Capsule().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                    }
                    .frame(maxWidth: 130)
                    Button(action: record) {
                        label("\(exercise.isTimedSets ? "Записать" : "Засчитать") \(WorkoutSetFormat.duration(max(chosen, 5)))",
                              icon: "checkmark")
                            .foregroundStyle(.white)
                            .background(Capsule().fill(Theme.accent))
                    }
                    .accessibilityIdentifier("timed-set-record")
                }
            }
        }
        .disabled(coordinator.isFinished)
        .onAppear(perform: prefill)
        .onChange(of: coordinator.currentSetIdx) { _, _ in prefill() }
        .onChange(of: coordinator.currentExerciseKey) { _, _ in prefill() }
    }

    /// The running watch, sized like the wheels so the card doesn't jump.
    private var stopwatch: some View {
        VStack(spacing: 4) {
            Text(WorkoutSetFormat.duration(holdTimer.elapsedSec))
                .font(.system(size: 48, weight: .ultraLight, design: .rounded).monospacedDigit())
                .foregroundStyle(holdTimer.reachedTarget ? Theme.accent : .white)
            if target > 0 {
                Text(holdTimer.reachedTarget ? "цель \(WorkoutSetFormat.duration(target)) есть" : "цель \(WorkoutSetFormat.duration(target))")
                    .font(.caption)
                    .foregroundStyle(holdTimer.reachedTarget ? Theme.accent : .white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 124)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
    }

    private func label(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold))
            Text(text).font(.body.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 48)
    }

    private func start() {
        Theme.hapticSend()
        restTimer.skip()
        holdTimer.start(targetSec: target)
    }

    private func stop() {
        Theme.hapticSend()
        set(WorkoutRunnerLogic.holdSeconds(holdTimer.stop()))
    }

    private func record() {
        Theme.hapticSend()
        let held = max(chosen, 5)
        holdTimer.reset()
        coordinator.logTimedSet(seconds: held)
        if exercise.isTimedSets {
            if exercise.restSec > 0 {
                restTimer.start(planned: exercise.restSec, lastRepsInReserve: 2)
            }
        } else {
            onWarmupDone()
        }
    }

    private func prefill() {
        guard !holdTimer.running else { return }
        set(WorkoutRunnerLogic.defaultHold(
            target: exercise.durationSec,
            lastLogged: coordinator.loggedForCurrentExercise.last?.durationSec))
    }

    private func set(_ total: Int) {
        let snapped = WorkoutRunnerLogic.holdSeconds(TimeInterval(total))
        minutes = snapped / 60
        seconds = snapped % 60
    }
}

/// Minutes | seconds wheels for a held time. Shared by the live card and the
/// edit sheet of an already-logged timed set.
struct HoldWheels: View {
    @Binding var minutes: Int
    @Binding var seconds: Int

    var body: some View {
        HStack(spacing: 10) {
            column(title: "Минуты") {
                Picker("Минуты", selection: $minutes) {
                    ForEach(WorkoutRunnerLogic.holdMinuteOptions, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            column(title: "Секунды") {
                Picker("Секунды", selection: $seconds) {
                    ForEach(WorkoutRunnerLogic.holdSecondOptions, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
            }
        }
    }

    @ViewBuilder
    private func column<P: View>(title: String, @ViewBuilder picker: () -> P) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.6))
            picker()
                .pickerStyle(.wheel)
                .frame(height: 100)
                .clipped()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
    }
}
