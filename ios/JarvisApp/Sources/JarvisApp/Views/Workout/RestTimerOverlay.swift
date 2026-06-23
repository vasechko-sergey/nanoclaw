import SwiftUI

/// Full-screen rest countdown shown after a set is logged. Classic-iOS circular
/// ring in the app's accent: the ring fills as rest elapses, remaining time in
/// the center, with a skip button.
struct RestTimerOverlay: View {
    @ObservedObject var timer: RestTimer
    /// Optional "подход 3 · 60 кг" hint for what's next.
    var nextHint: String? = nil

    var body: some View {
        if timer.running {
            ZStack {
                Theme.background.opacity(0.94).ignoresSafeArea()
                VStack(spacing: 28) {
                    Text("ОТДЫХ")
                        .font(.subheadline)
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.45))

                    ZStack {
                        Circle()
                            .stroke(Theme.accent.opacity(0.15), lineWidth: 12)
                        Circle()
                            .trim(from: 0, to: timer.progress)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: timer.progress)
                        VStack(spacing: 4) {
                            Text(format(timer.remainingSec))
                                .font(.system(size: 52, weight: .ultraLight, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                            Text("из \(format(timer.totalSec))")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .frame(width: 220, height: 220)

                    if let nextHint {
                        Text("Дальше: \(nextHint)")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Button { timer.skip() } label: {
                        Text("Пропустить")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 13)
                            .background(Capsule().fill(Theme.accent.opacity(0.16)))
                    }
                    .frame(minHeight: 44)
                }
            }
            .transition(.opacity)
        }
    }

    private func format(_ sec: Int) -> String {
        String(format: "%d:%02d", sec / 60, sec % 60)
    }
}
