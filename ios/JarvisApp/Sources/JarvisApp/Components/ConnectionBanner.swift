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
                    text: "Соединение потеряно",
                    color: Theme.offline,
                    showButton: true
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if showRestored {
                banner(
                    icon: "wifi",
                    text: "Соединение восстановлено",
                    color: Theme.online,
                    showButton: false
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: isConnected)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: showRestored)
        .onChange(of: isConnected) {
            if !isConnected {
                wasDisconnected = true
                showRestored = false
            } else if wasDisconnected {
                showRestored = true
                wasDisconnected = false
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { showRestored = false }
                }
            }
        }
    }

    private func banner(icon: String, text: String, color: Color, showButton: Bool) -> some View {
        HStack(spacing: Theme.scaled(6)) {
            // Match InputBar: same horizontal padding (scaled(8)) + icon in 44pt frame
            Image(systemName: icon)
                .font(.system(size: Theme.scaled(14)))
                .foregroundStyle(color)
                .frame(width: Theme.minTapSize, height: Theme.minTapSize)

            Text(text)
                .font(.system(size: Theme.fontSmall, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.8))
            Spacer()
            if showButton {
                Button {
                    Theme.hapticSend()
                    onReconnect()
                } label: {
                    Text("Переподключить")
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
        .padding(.horizontal, Theme.scaled(8))
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(color.opacity(0.3))
                .frame(height: 1)
        }
    }
}
