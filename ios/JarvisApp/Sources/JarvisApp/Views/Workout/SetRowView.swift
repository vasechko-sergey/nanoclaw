import SwiftUI

/// Read-only row for an already-logged set.
struct LoggedSetRow: View {
    let idx: Int
    let set: LoggedSet

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(idx + 1)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Text("\(set.reps) × \(formatWeight(set.weight)) кг")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text("ещё мог \(set.repsInReserve)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green.opacity(0.6))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.background.opacity(0.4)))
    }

    private func formatWeight(_ w: Double) -> String {
        let truncated = w.truncatingRemainder(dividingBy: 1) == 0
        return truncated ? String(Int(w)) : String(format: "%.1f", w)
    }
}

/// Editable row for the currently-active set.
struct ActiveSetRowView: View {
    @ObservedObject var coordinator: WorkoutCoordinator
    @ObservedObject var restTimer: RestTimer

    @State private var reps: Int = 8
    @State private var weight: Double = 20
    @State private var rir: Int = 2

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("#\(coordinator.currentSetIdx + 1)")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, alignment: .leading)
                Stepper("повторы \(reps)", value: $reps, in: 0...30)
                    .labelsHidden()
                Text("× \(reps)")
                    .font(.subheadline.monospacedDigit())
                Spacer()
            }
            HStack {
                Text("вес")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                Stepper(value: $weight, in: 0...500, step: 0.5) {
                    Text("\(formatWeight(weight)) кг")
                        .font(.subheadline.monospacedDigit())
                }
            }
            HStack {
                Text("запас")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Stepper("\(rir)", value: $rir, in: 0...10)
                    .labelsHidden()
                Text("\(rir) повторов")
                    .font(.subheadline.monospacedDigit())
                Spacer()
                Button {
                    let now = Date()
                    let planned = coordinator.currentExercise.restSec
                    coordinator.logSet(reps: reps, weight: weight, repsInReserve: rir, ts: now)
                    restTimer.start(planned: planned, lastRepsInReserve: rir)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.accent))
                }
                .accessibilityLabel("Записать подход")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
        .onAppear {
            // Pre-fill from last set of this exercise if any; else default.
            let prev = coordinator.loggedForCurrentExercise.last
            reps = prev?.reps ?? Self.midReps(exercise: coordinator.currentExercise)
            weight = prev?.weight ?? 20
            rir = coordinator.currentExercise.targetRir
        }
        .onChange(of: coordinator.currentSetIdx) { _, _ in
            let prev = coordinator.loggedForCurrentExercise.last
            reps = prev?.reps ?? reps
            weight = prev?.weight ?? weight
            rir = coordinator.currentExercise.targetRir
        }
        .onChange(of: coordinator.currentExerciseIdx) { _, _ in
            let prev = coordinator.loggedForCurrentExercise.last
            reps = prev?.reps ?? Self.midReps(exercise: coordinator.currentExercise)
            weight = prev?.weight ?? weight
            rir = coordinator.currentExercise.targetRir
        }
    }

    private func formatWeight(_ w: Double) -> String {
        let truncated = w.truncatingRemainder(dividingBy: 1) == 0
        return truncated ? String(Int(w)) : String(format: "%.1f", w)
    }

    private static func midReps(exercise: ExercisePlan) -> Int {
        // "8-10" → 9. "12" → 12. Falls back to 8.
        let parts = exercise.targetReps.split(separator: "-").compactMap { Int($0) }
        if parts.count == 2 { return (parts[0] + parts[1]) / 2 }
        if parts.count == 1 { return parts[0] }
        return 8
    }
}
