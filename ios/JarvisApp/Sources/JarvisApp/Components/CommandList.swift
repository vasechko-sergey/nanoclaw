import SwiftUI

struct CommandList: View {
    let commands: [BotCommand]
    /// When set, a header with a close (✕) is shown — used when the list was
    /// opened from the "+" menu (empty text), where there's otherwise no way to
    /// dismiss it without picking a command.
    var onClose: (() -> Void)? = nil
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onClose {
                HStack {
                    Text("Команды")
                        .font(.system(size: Theme.fontSubhead, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                }
                .padding(.leading, Theme.messagePadH)
                .padding(.trailing, Theme.scaled(6))
                .padding(.top, 4)
                Divider().background(Color.white.opacity(0.08)).padding(.leading, Theme.messagePadH)
            }
            ForEach(commands, id: \.command) { cmd in
                Button {
                    onSelect(cmd.command)
                } label: {
                    HStack(spacing: 0) {
                        Text(cmd.command)
                            .font(.system(size: Theme.fontBody, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .frame(minWidth: Theme.scaled(90), alignment: .leading)
                        Text(cmd.description)
                            .font(.system(size: Theme.fontSubhead))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Theme.messagePadH)
                    .padding(.vertical, Theme.scaled(12))
                    .frame(minHeight: Theme.minTapSize)
                }
                if cmd != commands.last {
                    Divider()
                        .background(Color.white.opacity(0.08))
                        .padding(.leading, Theme.messagePadH)
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.surfaceBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Theme.scaled(12))
        .padding(.bottom, 4)
        .shadow(color: .black.opacity(0.4), radius: 10, y: -4)
    }
}
