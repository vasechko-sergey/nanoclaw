import SwiftUI

/// Image hero for the runner. Shows the *previewed* exercise; swipe / chevrons
/// move the preview. Top controls (progress, close, advance) live in the
/// pinned header owned by WorkoutView.
struct ExerciseBannerView: View {
    let exercise: ExercisePlan
    let imageURL: URL?
    let stateTag: String          // "подход 2 из 4" / "ещё не начато" / "бонусный подход"
    var canPrev: Bool
    var canNext: Bool
    var onPreview: (_ delta: Int) -> Void

    var body: some View {
        ZStack {
            if let url = imageURL, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Theme.surface
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 70)).foregroundStyle(Theme.accent.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .leading) {
            if canPrev { chevron("chevron.left") { onPreview(-1) } }
        }
        .overlay(alignment: .trailing) {
            if canNext { chevron("chevron.right") { onPreview(1) } }
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text(exercise.displayName).font(.headline).foregroundStyle(.white)
                Spacer()
                Text(stateTag).font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.black.opacity(0.74))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { v in
                    if v.translation.width < -40 { onPreview(1) }
                    else if v.translation.width > 40 { onPreview(-1) }
                }
        )
    }

    private func chevron(_ sys: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: sys).foregroundStyle(.white.opacity(0.7))
                .frame(width: 30, height: 48)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(6)
    }
}
