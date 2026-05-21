import SwiftUI

private let teal    = Color(red: 0.33, green: 0.74, blue: 0.77)
private let inputBg = Color(red: 0.09, green: 0.16, blue: 0.22)
private let barBg   = Color(red: 0.07, green: 0.11, blue: 0.15)

struct InputBar: View {
    @Binding var text: String
    let commands: [BotCommand]
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
            HStack(spacing: 4) {
                Button {
                    showAll.toggle()
                    if showAll && !text.hasPrefix("/") { text = "" }
                } label: {
                    Text("/")
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(showAll ? teal : teal.opacity(0.4))
                        .frame(width: 30, height: 30)
                }

                TextField("Сообщение...", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .foregroundStyle(Color.white)
                    .tint(teal)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .onChange(of: text) {
                        if showAll && !text.hasPrefix("/") { showAll = false }
                    }

                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(teal)
                        .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.25 : 1.0)
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(barBg)
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
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(red: 0.33, green: 0.74, blue: 0.77))
                            .frame(minWidth: 90, alignment: .leading)
                        Text(cmd.description)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                if cmd != commands.last {
                    Divider()
                        .background(Color.white.opacity(0.08))
                        .padding(.leading, 14)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.16, blue: 0.22))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .shadow(color: .black.opacity(0.4), radius: 10, y: -4)
    }
}
