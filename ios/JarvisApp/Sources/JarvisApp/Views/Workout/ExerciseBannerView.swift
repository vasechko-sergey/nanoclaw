import SwiftUI

/// Large image hero for the runner's top ~half. Aspect-fills the exercise
/// image (placeholder when missing), with an overlaid top bar (close /
/// progress / advance) and a bottom scrim carrying the Russian name + position.
struct ExerciseBannerView: View {
    let exercise: ExercisePlan
    let imageURL: URL?
    let indexLabel: String
    let current: Int
    let total: Int
    let isLast: Bool
    var onClose: () -> Void
    var onAdvance: () -> Void

    var body: some View {
        ZStack {
            if let url = imageURL, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Theme.surface
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 70))
                    .foregroundStyle(Theme.accent.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .top) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.body)
                        .foregroundStyle(.white).frame(width: 40, height: 40)
                }
                HStack(spacing: 3) {
                    ForEach(0..<max(total, 1), id: \.self) { i in
                        Capsule()
                            .fill(i <= current ? Theme.accent : Color.white.opacity(0.25))
                            .frame(height: 3)
                    }
                }
                Button(action: onAdvance) {
                    Text(isLast ? "Финиш" : "Дальше →")
                        .font(.subheadline).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.45))
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text(exercise.displayName).font(.headline).foregroundStyle(.white)
                Spacer()
                Text(indexLabel).font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.74))
        }
    }
}
