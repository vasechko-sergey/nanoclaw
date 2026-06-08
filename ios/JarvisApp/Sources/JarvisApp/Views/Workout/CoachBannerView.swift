import SwiftUI

struct CoachBannerView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.fill.badge.minus")
                .foregroundStyle(.orange.opacity(0.7))
                .font(.body)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.orange.opacity(0.4), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }
}
