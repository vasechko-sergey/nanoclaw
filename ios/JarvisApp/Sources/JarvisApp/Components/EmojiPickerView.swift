import SwiftUI

private let emojis: [String] = [
    "🏠", "💻", "🏄", "🏋️", "🚗", "✈️",
    "🍽️", "☕", "😴", "🏃", "📚", "🎵",
    "🤒", "🎮", "🌊", "🏖️", "🧘", "🎯",
]

struct EmojiPickerView: View {
    @Binding var selected: String
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)

    var body: some View {
        VStack(spacing: Theme.scaled(8)) {
            Text("Статус")
                .font(.system(size: Theme.fontCaption, weight: .medium))
                .foregroundStyle(Theme.accentMedium)
                .padding(.top, Theme.scaled(4))

            LazyVGrid(columns: columns, spacing: Theme.scaled(4)) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        selected = (selected == emoji) ? "" : emoji
                        dismiss()
                    } label: {
                        Text(emoji)
                            .font(.system(size: Theme.scaled(26)))
                            .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                            .background(selected == emoji
                                ? Theme.accent.opacity(0.2)
                                : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.scaled(8)))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.scaled(8))
                                    .stroke(selected == emoji
                                        ? Theme.accent.opacity(0.3)
                                        : Color.clear, lineWidth: 0.5)
                            )
                    }
                }
            }

            if !selected.isEmpty {
                Button {
                    selected = ""
                    dismiss()
                } label: {
                    Text("Убрать статус")
                        .font(.system(size: Theme.fontCaption))
                        .foregroundStyle(Theme.accentMedium)
                }
                .frame(minHeight: Theme.minTapSize)
            }
        }
        .padding(Theme.scaled(12))
        .frame(width: Theme.scaled(312))
        .background(Theme.surface)
    }
}
