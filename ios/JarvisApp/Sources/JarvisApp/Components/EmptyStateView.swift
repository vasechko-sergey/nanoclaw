import SwiftUI

struct EmptyStateView: View {
    var onSuggestion: (String) -> Void

    private let suggestions = [
        "Погода", "Расписание", "Новости", "Напомни",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            OrbView(size: Theme.orbSize, brightness: 0.8)

            Text("Чем могу помочь?")
                .font(.system(size: Theme.fontSubhead, weight: .regular))
                .foregroundStyle(Theme.accent.opacity(0.35))
                .padding(.top, Theme.scaled(20))

            // Suggestion chips — wrap on small screens via ViewThatFits
            ViewThatFits(in: .horizontal) {
                chipRow
                chipGrid
            }
            .padding(.top, Theme.scaled(24))
            .padding(.horizontal, Theme.hPadding)

            Spacer()
        }
    }

    private var chipRow: some View {
        HStack(spacing: Theme.scaled(10)) {
            ForEach(suggestions, id: \.self) { text in
                chip(for: text)
            }
        }
    }

    private var chipGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: Theme.scaled(8))],
                  spacing: Theme.scaled(8)) {
            ForEach(suggestions, id: \.self) { text in
                chip(for: text)
            }
        }
    }

    private func chip(for text: String) -> some View {
        Button {
            Theme.hapticSend()
            onSuggestion(text)
        } label: {
            Text(text)
                .font(.system(size: Theme.fontChip))
                .foregroundStyle(Theme.accent.opacity(0.5))
                .padding(.horizontal, Theme.scaled(16))
                .padding(.vertical, Theme.scaled(10))
                .background(
                    RoundedRectangle(cornerRadius: Theme.chipRadius)
                        .stroke(Theme.accent.opacity(0.15), lineWidth: 0.5)
                )
        }
        .frame(minHeight: Theme.minTapSize)
    }
}
