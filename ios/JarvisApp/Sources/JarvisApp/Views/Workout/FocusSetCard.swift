import SwiftUI

/// Big-control set logger for the runner: three aligned stepper rows
/// (Повторы / Вес / Запас) + the primary "Записать подход" button. Owns the
/// editable set state + pre-fill, and logs through the coordinator. Migrated
/// from the former `ActiveSetRowView` with the same wiring.
struct FocusSetCard: View {
    @ObservedObject var coordinator: WorkoutCoordinator
    @ObservedObject var restTimer: RestTimer

    @State private var reps = 8
    @State private var weight: Double = 20
    @State private var rir = 2

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                stepperRow(label: "Повторы", value: "\(reps)",
                           onMinus: { reps = max(0, reps - 1) },
                           onPlus: { reps = min(30, reps + 1) })
                Divider().overlay(Color.white.opacity(0.06))
                stepperRow(label: "Вес, кг", value: WorkoutSetFormat.weight(weight),
                           onMinus: { weight = max(0, weight - 0.5) },
                           onPlus: { weight = min(500, weight + 0.5) })
                Divider().overlay(Color.white.opacity(0.06))
                stepperRow(label: "Запас", value: "\(rir)",
                           onMinus: { rir = max(0, rir - 1) },
                           onPlus: { rir = min(10, rir + 1) })
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.07), lineWidth: 0.5))

            Button(action: logCurrent) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .bold))
                    Text("Записать подход").font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(Theme.accent))
            }
            .disabled(coordinator.isFinished)
        }
        .onAppear(perform: prefill)
        .onChange(of: coordinator.currentSetIdx) { _, _ in prefillKeepWeight() }
        .onChange(of: coordinator.currentExerciseIdx) { _, _ in prefill() }
    }

    private func logCurrent() {
        Theme.hapticSend()
        coordinator.logSet(reps: reps, weight: weight, repsInReserve: rir, ts: Date())
        restTimer.start(planned: coordinator.currentExercise.restSec, lastRepsInReserve: rir)
    }

    private func prefill() {
        let prev = coordinator.loggedForCurrentExercise.last
        reps = prev?.reps ?? WorkoutSetFormat.midReps(targetReps: coordinator.currentExercise.targetReps)
        weight = prev?.weight ?? weight
        rir = coordinator.currentExercise.targetRir
    }

    private func prefillKeepWeight() {
        let prev = coordinator.loggedForCurrentExercise.last
        reps = prev?.reps ?? reps
        weight = prev?.weight ?? weight
        rir = coordinator.currentExercise.targetRir
    }

    @ViewBuilder
    private func stepperRow(label: String, value: String,
                            onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.65))
            Spacer()
            HStack(spacing: 14) {
                circle("minus", onMinus)
                Text(value)
                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                    .frame(width: 44)
                    .foregroundStyle(.white)
                circle("plus", onPlus)
            }
        }
        .padding(.vertical, 11)
    }

    private func circle(_ sys: String, _ act: @escaping () -> Void) -> some View {
        Button(action: { Theme.hapticSend(); act() }) {
            Image(systemName: sys)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}
