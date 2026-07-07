import SwiftUI

/// Compact chip strip of the current exercise's logged sets + a muted
/// "подход N из M" position chip. Sets with a Payne coach hint get a
/// 💬 badge; tapping opens a sheet with the hint text.
struct LoggedSetChips: View {
    let logged: [LoggedSet]
    let currentSetIdx: Int
    let targetSets: Int
    @State private var tappedIdx: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(logged.enumerated()), id: \.offset) { idx, s in
                chipButton(idx: idx, set: s)
            }
            if let label = WorkoutRunnerLogic.setLabel(currentSetIdx: currentSetIdx, targetSets: targetSets) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: Binding(
            get: { tappedIdx != nil },
            set: { if !$0 { tappedIdx = nil } }
        )) {
            if let idx = tappedIdx, logged.indices.contains(idx),
               let text = logged[idx].coachHint {
                VStack(spacing: 12) {
                    Text("Пейн").font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text(text).font(.body).multilineTextAlignment(.leading)
                    Button("Закрыть") { tappedIdx = nil }
                }
                .padding(20)
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private func chipButton(idx: Int, set: LoggedSet) -> some View {
        Button {
            if set.coachHint != nil { tappedIdx = idx }
        } label: {
            HStack(spacing: 3) {
                Text("✓ \(set.reps)×\(WorkoutSetFormat.weight(set.weight))")
                if set.coachHint != nil {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10))
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .disabled(set.coachHint == nil)
    }
}
