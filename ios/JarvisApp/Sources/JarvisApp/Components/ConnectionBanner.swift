import SwiftUI

/// Hairline strip under the chat header. 28pt tall when disconnected, 0pt when connected.
struct ConnectionBanner: View {
    let isConnected: Bool
    var onTap: () -> Void

    @State private var pulseScale: CGFloat = 1

    var body: some View {
        Group {
            if !isConnected {
                Button(action: onTap) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                            .scaleEffect(pulseScale)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                    pulseScale = 1.4
                                }
                            }
                        Text("Восстанавливаю связь...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.hPadding)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .offset(y: -10)))
            }
        }
        .animation(.easeOut(duration: Theme.animMedium), value: isConnected)
    }
}
