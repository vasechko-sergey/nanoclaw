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
                // 180pt is plenty for one or two coach sentences and leaves the
                // running set visible behind it; .medium is there if the text is
                // long. A half/full-screen default buried the runner.
                .presentationDetents([.height(180), .medium])
                .presentationDragIndicator(.visible)
            } else {
                // Race: the hint was cleared (swap / new plan) between the tap
                // and this render. Dismiss instead of showing a blank sheet.
                Color.clear.onAppear { tappedIdx = nil }
            }
        }
    }

    @ViewBuilder
    private func chipButton(idx: Int, set: LoggedSet) -> some View {
        // Badge marks a set that deviated from plan; the accent outline + tap
        // sheet are driven by Payne's coachHint — separate signals.
        let hasHint = set.coachHint != nil
        Button {
            if hasHint { tappedIdx = idx }
        } label: {
            HStack(spacing: 4) {
                Text("✓ \(set.reps)×\(WorkoutSetFormat.weight(set.weight))")
                if !set.deviations.isEmpty {
                    // Prominent enough to catch the eye mid-set: 14pt bubble in a
                    // filled 20pt accent circle, not a 10pt tint that blends in.
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.accent))
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.15)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Theme.accent, lineWidth: hasHint ? 1.5 : 0)
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasHint)
    }
}
