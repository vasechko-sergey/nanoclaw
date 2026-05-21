import SwiftUI

struct InputBar: View {
    @Binding var text: String
    let commands: [BotCommand]
    var isDisabled: Bool = false
    var enterToSend: Bool = true
    let onSend: () -> Void

    @State private var showAll = false

    private var filteredCommands: [BotCommand] {
        if showAll { return commands }
        guard text.hasPrefix("/") else { return [] }
        let q = text.lowercased()
        return q == "/" ? commands : commands.filter { $0.command.lowercased().hasPrefix(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !filteredCommands.isEmpty {
                CommandList(commands: filteredCommands) { cmd in
                    text = cmd
                    showAll = false
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: Theme.scaled(6)) {
                Button {
                    showAll.toggle()
                    if showAll && !text.hasPrefix("/") { text = "" }
                } label: {
                    Text("/")
                        .font(.system(size: Theme.scaled(22), weight: .medium, design: .monospaced))
                        .foregroundStyle(showAll ? Theme.accent : Theme.accent.opacity(0.3))
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
                .accessibilityLabel("Команды")

                TextField("Спросить Jarvis...", text: $text, axis: .vertical)
                    .font(.system(size: Theme.fontInput))
                    .lineLimit(1...5)
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                    .padding(.horizontal, Theme.messagePadH)
                    .padding(.vertical, Theme.messagePadV)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.inputRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.inputRadius)
                            .stroke(Theme.surfaceBorder, lineWidth: 0.5)
                    )
                    .onChange(of: text) {
                        if showAll && !text.hasPrefix("/") { showAll = false }
                    }
                    .onSubmit {
                        if enterToSend && !isDisabled {
                            Theme.hapticSend()
                            onSend()
                        }
                    }
                    .submitLabel(enterToSend ? .send : .return)
                    .accessibilityLabel("Поле ввода сообщения")

                Button(action: {
                    Theme.hapticSend()
                    onSend()
                }) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: Theme.scaled(32)))
                        .foregroundStyle(Theme.accent)
                        .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.2 : 1.0)
                }
                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isDisabled)
                .accessibilityLabel("Отправить")
            }
            .padding(.horizontal, Theme.scaled(8))
            .padding(.vertical, Theme.scaled(8))
            .background(Theme.background)
            .opacity(isDisabled ? 0.4 : 1.0)
            .allowsHitTesting(!isDisabled)
        }
        .animation(.easeInOut(duration: 0.15), value: filteredCommands.isEmpty)
    }
}

private struct CommandList: View {
    let commands: [BotCommand]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
