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

    /// Opacity that scales with brightness but never drops below a visible floor.
    private func op(_ base: CGFloat, floor: CGFloat = 0) -> Double {
        max(base * brightness, floor)
    }

    var body: some View {
        ZStack {
            // Outer breath ring
            Circle()
                .fill(Theme.accent.opacity(op(0.06, floor: 0.02)))
                .frame(width: size * 0.46, height: size * 0.46)
                .scaleEffect(pulse)

            // Outer ring
            Circle()
                .stroke(Theme.accent.opacity(op(0.25, floor: 0.08)), lineWidth: 0.5)
                .frame(width: ringOuter * 2, height: ringOuter * 2)
                .scaleEffect(pulse)

            // Middle ring — slow rotate
            Circle()
                .trim(from: 0.0, to: 0.7)
                .stroke(
                    AngularGradient(
                        colors: [Theme.accent.opacity(0), Theme.accent.opacity(op(0.5, floor: 0.12))],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 0.8, lineCap: .round)
                )
                .frame(width: ringMiddle * 2, height: ringMiddle * 2)
                .rotationEffect(.degrees(rotation))

            // Inner ring
            Circle()
                .stroke(Theme.accent.opacity(op(0.4, floor: 0.1)), lineWidth: 0.6)
                .frame(width: ringInner * 2, height: ringInner * 2)

            // Inner glow
            Circle()
                .fill(Theme.accent.opacity(op(0.15, floor: 0.04)))
                .frame(width: glowSize * 2, height: glowSize * 2)
                .scaleEffect(innerPulse)

            // Core dot
            Circle()
                .fill(Theme.accent.opacity(op(0.95, floor: 0.25)))
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
