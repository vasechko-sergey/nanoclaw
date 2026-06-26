import SwiftUI

/// Compact chip strip of the current exercise's logged sets + a muted
/// "подход N из M" position chip. Replaces the stacked logged-set rows.
struct LoggedSetChips: View {
    let logged: [LoggedSet]
    let currentSetIdx: Int
    let targetSets: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(logged.enumerated()), id: \.offset) { _, s in
                chip("✓ \(s.reps)×\(WorkoutSetFormat.weight(s.weight))", filled: true)
            }
            if let label = WorkoutRunnerLogic.setLabel(currentSetIdx: currentSetIdx, targetSets: targetSets) {
                chip(label, filled: false)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(filled ? Theme.accent : .white.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(filled ? Theme.accent.opacity(0.15) : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(filled ? .clear : Color.white.opacity(0.08), lineWidth: 0.5))
    }
}
