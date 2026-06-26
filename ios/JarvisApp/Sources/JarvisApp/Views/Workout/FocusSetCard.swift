import SwiftUI

/// Set logger for the runner: side-by-side `Повторы` / `Вес` wheels (a wheel is
/// vertical, so two columns share one wheel-height row instead of stacking),
/// `Запас` buttons (0/1/2/4), and the primary "Записать подход" button. Owns the
/// editable set state, seeds defaults from Payne's plan (weight_kg_target /
/// target_reps / reps_in_reserve), logs through the coordinator.
struct FocusSetCard: View {
    @ObservedObject var coordinator: WorkoutCoordinator
    @ObservedObject var restTimer: RestTimer

    @State private var reps = 8
    @State private var weight: Double = 20
    @State private var rir = 2

    /// Dark teal used for text sitting on the accent fill.
    private let onAccent = Color(red: 0.02, green: 0.16, blue: 0.17)

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                wheelColumn(title: "Повторы") {
                    Picker("Повторы", selection: $reps) {
                        ForEach(WorkoutRunnerLogic.repsOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                wheelColumn(title: "Вес, кг") {
                    Picker("Вес", selection: $weight) {
                        ForEach(WorkoutRunnerLogic.weightOptions, id: \.self) { Text(WorkoutSetFormat.weight($0)).tag($0) }
                    }
                }
            }
            rirRow

            Button(action: logCurrent) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .bold))
                    Text("Записать подход").font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Capsule().fill(Theme.accent))
            }
            .disabled(coordinator.isFinished)
        }
        .onAppear(perform: prefill)
        .onChange(of: coordinator.currentSetIdx) { _, _ in prefillKeepWeight() }
        .onChange(of: coordinator.currentExerciseIdx) { _, _ in prefill() }
    }

    @ViewBuilder
    private func wheelColumn<P: View>(title: String, @ViewBuilder picker: () -> P) -> some View {
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

    private var rirRow: some View {
        HStack {
            Text("Запас").foregroundStyle(.white.opacity(0.65))
            Spacer()
            HStack(spacing: 8) {
                ForEach(WorkoutRunnerLogic.rirButtons, id: \.self) { v in
                    Button { Theme.hapticSend(); rir = v } label: {
                        Text("\(v)")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 40, height: 36)
                            .foregroundStyle(rir == v ? onAccent : .white.opacity(0.6))
                            .background(RoundedRectangle(cornerRadius: 10).fill(rir == v ? Theme.accent : Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func logCurrent() {
        Theme.hapticSend()
        coordinator.logSet(reps: reps, weight: weight, repsInReserve: rir, ts: Date())
        restTimer.start(planned: coordinator.currentExercise.restSec, lastRepsInReserve: rir)
    }

    private func prefill() {
        let prev = coordinator.loggedForCurrentExercise.last
        reps = min(max(prev?.reps ?? WorkoutSetFormat.midReps(targetReps: coordinator.currentExercise.targetReps), 1), 30)
        weight = WorkoutRunnerLogic.defaultWeight(
            target: coordinator.currentExercise.weightKgTarget, lastLogged: prev?.weight)
        rir = WorkoutRunnerLogic.snapRir(coordinator.currentExercise.targetRir)
    }

    private func prefillKeepWeight() {
        let prev = coordinator.loggedForCurrentExercise.last
        reps = min(max(prev?.reps ?? reps, 1), 30)
        if let w = prev?.weight { weight = w }
        rir = WorkoutRunnerLogic.snapRir(coordinator.currentExercise.targetRir)
    }
}
