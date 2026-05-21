import SwiftUI

/// Reusable pulsing orb — the visual "heartbeat" of Jarvis.
/// Used in splash screen, empty chat state, and profile.
struct OrbView: View {
    var size: CGFloat = 120
    var brightness: Double = 1.0

    @State private var pulse: CGFloat = 1
    @State private var rotation: Double = 0
    @State private var innerPulse: CGFloat = 1

    private var ringOuter: CGFloat { size * 0.42 }
    private var ringMiddle: CGFloat { size * 0.30 }
    private var ringInner: CGFloat { size * 0.18 }
    private var glowSize: CGFloat { size * 0.10 }
    private var coreSize: CGFloat { size * 0.025 }

    var body: some View {
        ZStack {
            // Outer breath ring
            Circle()
                .fill(Theme.accent.opacity(0.04 * brightness))
                .frame(width: size * 0.46, height: size * 0.46)
                .scaleEffect(pulse)

            // Outer ring
            Circle()
                .stroke(Theme.accent.opacity(0.12 * brightness), lineWidth: 0.4)
                .frame(width: ringOuter * 2, height: ringOuter * 2)
                .scaleEffect(pulse)

            // Middle ring — slow rotate
            Circle()
                .trim(from: 0.0, to: 0.7)
                .stroke(
                    AngularGradient(
                        colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.25 * brightness)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 0.6, lineCap: .round)
                )
                .frame(width: ringMiddle * 2, height: ringMiddle * 2)
                .rotationEffect(.degrees(rotation))

            // Inner ring
            Circle()
                .stroke(Theme.accent.opacity(0.2 * brightness), lineWidth: 0.6)
                .frame(width: ringInner * 2, height: ringInner * 2)

            // Inner glow
            Circle()
                .fill(Theme.accent.opacity(0.08 * brightness))
                .frame(width: glowSize * 2, height: glowSize * 2)
                .scaleEffect(innerPulse)

            // Core dot
            Circle()
                .fill(Theme.accent.opacity(0.7 * brightness))
                .frame(width: coreSize * 2, height: coreSize * 2)
                .scaleEffect(innerPulse)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                pulse = 1.08
            }
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                innerPulse = 1.4
            }
        }
    }
}
