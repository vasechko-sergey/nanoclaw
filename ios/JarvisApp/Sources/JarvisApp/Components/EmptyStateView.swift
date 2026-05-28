import SwiftUI

struct EmptyStateView: View {
    var onSuggestion: (String) -> Void
    var onStartVoice: () -> Void
    var onStartText: () -> Void

    private let suggestions = [
        "Что в календаре на сегодня?",
        "Покажи последние задачи",
        "Сделай резюме рабочего дня"
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            MiniOrbView(size: 96, mood: .calm)

            Text("О чём поговорим?")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { onSuggestion(s) } label: {
                            Text(s)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .overlay(
                                    Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: Theme.lineHairline)
                                )
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, Theme.hPadding)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: onStartVoice) {
                    HStack {
                        Image(systemName: "mic.fill")
                        Text("Голосом")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: Theme.lineHairline))
                    .clipShape(Capsule())
                }

                Button(action: onStartText) {
                    HStack {
                        Image(systemName: "keyboard")
                        Text("Текстом")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: Theme.lineHairline))
                    .clipShape(Capsule())
                }
                .accessibilityIdentifier("empty-start-text")
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
