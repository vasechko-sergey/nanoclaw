import SwiftUI

struct ConnectionBanner: View {
    let isConnected: Bool
    let onReconnect: () -> Void

    @State private var showRestored = false
    @State private var wasDisconnected = false

    var body: some View {
        VStack(spacing: 0) {
            if !isConnected {
                banner(
                    icon: "wifi.slash",
                    text: "Нет подключения",
                    color: Theme.offline,
                    showButton: true
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if showRestored {
                banner(
                    icon: "wifi",
                    text: "Подключено",
                    color: Theme.online,
                    showButton: false
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: isConnected)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: showRestored)
        .onChange(of: isConnected) { _, connected in
            if !connected {
                wasDisconnected = true
                showRestored = false
            } else if wasDisconnected {
                showRestored = true
                wasDisconnected = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showRestored = false }
                }
            }
        }
    }

    private func banner(icon: String, text: String, color: Color, showButton: Bool) -> some View {
        HStack(spacing: Theme.scaled(8)) {
            Image(systemName: icon)
                .font(.system(size: Theme.scaled(14)))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: Theme.fontSmall, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.8))
            Spacer()
            if showButton {
                Button {
                    Theme.hapticSend()
                    onReconnect()
                } label: {
                    Text("Повторить")
                        .font(.system(size: Theme.fontSmall, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Theme.scaled(12))
                        .padding(.vertical, Theme.scaled(6))
                        .background(Theme.accent.opacity(0.12))
                        .clipShape(Capsule())
                }
                .frame(minHeight: Theme.minTapSize)
            }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.vertical, Theme.scaled(6))
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(color.opacity(0.3))
                .frame(height: 1)
        }
    }
}
