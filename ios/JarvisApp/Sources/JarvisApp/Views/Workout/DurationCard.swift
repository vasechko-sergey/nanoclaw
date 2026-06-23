import SwiftUI

/// Card for a timed exercise (treadmill / warmup) — no sets. Shows the target
/// duration and a "Засчитать" button that marks the exercise done (the user
/// self-times). Replaces FocusSetCard when `exercise.isDuration`.
struct DurationCard: View {
    let exercise: ExercisePlan
    var onDone: () -> Void

    private var seconds: Int { exercise.durationSec ?? 0 }
    private var minutesText: String {
        let m = max(1, Int((Double(seconds) / 60).rounded()))
        return "цель — \(m) мин"
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 22)).foregroundStyle(Theme.accent.opacity(0.7))
                    Text(WorkoutSetFormat.duration(seconds))
                        .font(.system(size: 40, weight: .ultraLight, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
                Text(minutesText).font(.caption).foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.07), lineWidth: 0.5))

            Button(action: { Theme.hapticSend(); onDone() }) {
                Text("Засчитать")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(Theme.accent))
            }
        }
    }
}
