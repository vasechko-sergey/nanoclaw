import SwiftUI

/// The ⅓-screen panel under the image showing Payne's recommendation for the
/// (previewed) exercise. All data comes from the plan — nothing computed here.
/// Plain language, no abbreviations (house style).
struct RecommendationPanel: View {
    let exercise: ExercisePlan

    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(copper)
                Text("РЕКОМЕНДАЦИЯ ПЕЙНА").font(.caption2).tracking(0.3).foregroundStyle(copper)
            }
            HStack(spacing: 7) {
                if let w = exercise.weightKgTarget { chip("\(WorkoutSetFormat.weight(w)) кг") }
                if exercise.targetSets > 0 { chip("\(exercise.targetSets) × \(exercise.targetReps)") }
                chip("запас \(exercise.targetRir)")
                if exercise.restSec > 0 { chip("отдых \(restLabel(exercise.restSec))") }
            }
            if let notes = exercise.notes, !notes.isEmpty {
                Text(notes).font(.footnote).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(red: 0.08, green: 0.078, blue: 0.06))
        .overlay(alignment: .top) { Rectangle().fill(copper.opacity(0.35)).frame(height: 1) }
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.subheadline).foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
    }

    private func restLabel(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}
