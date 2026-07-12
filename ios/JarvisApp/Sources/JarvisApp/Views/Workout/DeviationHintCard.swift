import SwiftUI

/// Prominent copper card for Payne's *deviation* reply (a `coach_message` WITH
/// `set_ref`). Sits directly above the set input so it's read BEFORE the next
/// set — Payne only sends these on a strong deviation, so they earn the space
/// rather than hiding as a badge on a scrolled-away logged-set chip.
///
/// Tap ✕ to dismiss; it also clears automatically when the next set is logged
/// or the exercise is finished (see `WorkoutCoordinator.activeDeviationHint`).
struct DeviationHintCard: View {
    let text: String
    var onDismiss: () -> Void

    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(copper)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Пейн · расхождение")
                    .font(.caption2)
                    .foregroundStyle(copper)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Скрыть подсказку")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(copper.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(copper.opacity(0.55), lineWidth: 1))
        .accessibilityIdentifier("deviation-hint-card")
    }
}
