import SwiftUI

/// Big-control set logger for the runner: reps stepper + weight wheel + запас
/// buttons (0/1/2/4) + the primary "Записать подход" button. Owns the editable
/// set state, seeds defaults from Payne's plan (weight_kg_target / target_reps /
/// reps_in_reserve), and logs through the coordinator.
struct FocusSetCard: View {
    @ObservedObject var coordinator: WorkoutCoordinator
    @ObservedObject var restTimer: RestTimer

    @State private var reps = 8
    @State private var weight: Double = 20
    @State private var rir = 2

    /// Dark teal used for text sitting on the accent fill.
    private let onAccent = Color(red: 0.02, green: 0.16, blue: 0.17)
    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                stepperRow(label: "Повторы", value: "\(reps)",
                           onMinus: { reps = max(0, reps - 1) },
                           onPlus: { reps = min(30, reps + 1) })
                Divider().overlay(Color.white.opacity(0.06))
                weightRow
                Divider().overlay(Color.white.opacity(0.06))
                rirRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
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

    private var weightRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Вес, кг").foregroundStyle(.white.opacity(0.65))
                Spacer()
                if let t = coordinator.currentExercise.weightKgTarget {
                    Text("Пейн: \(WorkoutSetFormat.weight(t))").font(.caption).foregroundStyle(copper)
                }
            }
            Picker("Вес", selection: $weight) {
                ForEach(WorkoutRunnerLogic.weightOptions, id: \.self) { w in
                    Text(WorkoutSetFormat.weight(w)).tag(w)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 110)
            .clipped()
        }
        .padding(.vertical, 8)
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
        .padding(.vertical, 11)
    }

    private func logCurrent() {
        Theme.hapticSend()
        coordinator.logSet(reps: reps, weight: weight, repsInReserve: rir, ts: Date())
        restTimer.start(planned: coordinator.currentExercise.restSec, lastRepsInReserve: rir)
    }

    private func prefill() {
        let prev = coordinator.loggedForCurrentExercise.last
        reps = prev?.reps ?? WorkoutSetFormat.midReps(targetReps: coordinator.currentExercise.targetReps)
        weight = WorkoutRunnerLogic.defaultWeight(
            target: coordinator.currentExercise.weightKgTarget, lastLogged: prev?.weight)
        rir = WorkoutRunnerLogic.snapRir(coordinator.currentExercise.targetRir)
    }

    private func prefillKeepWeight() {
        let prev = coordinator.loggedForCurrentExercise.last
        reps = prev?.reps ?? reps
        if let w = prev?.weight { weight = w }
        rir = WorkoutRunnerLogic.snapRir(coordinator.currentExercise.targetRir)
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
