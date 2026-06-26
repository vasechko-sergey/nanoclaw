import SwiftUI

/// The ⅓-screen panel under the image showing Payne's recommendation for the
/// (previewed) exercise. All data comes from the plan — nothing computed here.
/// Plain language, no abbreviations (house style).
struct RecommendationPanel: View {
    let exercise: ExercisePlan

    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(copper)
            Text("ПЕЙН").font(.caption2).foregroundStyle(copper)
            if let w = exercise.weightKgTarget { chip("\(WorkoutSetFormat.weight(w)) кг") }
            if exercise.targetSets > 0 { chip("\(exercise.targetSets)×\(exercise.targetReps)") }
            chip("запас \(exercise.targetRir)")
            if exercise.restSec > 0 { chip(restLabel(exercise.restSec)) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(red: 0.08, green: 0.078, blue: 0.06))
        .overlay(alignment: .top) { Rectangle().fill(copper.opacity(0.35)).frame(height: 1) }
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
    }

    private func restLabel(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}
