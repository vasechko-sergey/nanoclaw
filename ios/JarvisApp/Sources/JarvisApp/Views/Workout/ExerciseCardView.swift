import SwiftUI

struct ExerciseCardView: View {
    let exercise: ExercisePlan
    let imageURL: URL?     // nil while image is in-flight; placeholder shown
    let onSwap: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Schematic image area (square aspect, rounded corners).
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.background.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Theme.accent.opacity(0.15), lineWidth: 1)
                    )
                if let url = imageURL, let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: 56, weight: .ultraLight))
                        .foregroundStyle(Theme.accent.opacity(0.4))
                }
            }
            .aspectRatio(1.0, contentMode: .fit)
            .frame(maxWidth: 320)

            // Title + targets.
            VStack(spacing: 4) {
                Text(exercise.exerciseSlug.replacingOccurrences(of: "-", with: " "))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(exercise.targetSets) × \(exercise.targetReps) · запас \(exercise.targetRir) повторов · отдых \(exercise.restSec) сек")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let notes = exercise.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.footnote.italic())
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .multilineTextAlignment(.center)

            // Swap button — small, secondary.
            Button(action: onSwap) {
                Label("заменить", systemImage: "arrow.2.squarepath")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
    }
}
