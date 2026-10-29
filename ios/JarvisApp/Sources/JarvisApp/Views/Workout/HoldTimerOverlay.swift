import SwiftUI

/// Full-screen hold ring for a plank / isometric hold / warmup, opened by
/// «Старт» on the timed card. Built like RestTimerOverlay so it reads from the
/// floor: the ring fills up to the target, then stays full while the count
/// goes on («цель есть · +0:07»). «Стоп» hands the time back to the card.
struct HoldTimerOverlay: View {
    @ObservedObject var timer: HoldTimer
    let title: String
    var onStop: () -> Void

    var body: some View {
        if timer.running {
            ZStack {
                Theme.background.opacity(0.96).ignoresSafeArea()
                VStack(spacing: 28) {
                    Text(title)
                        .font(.subheadline)
                        .tracking(1.5)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 32)

                    ZStack {
                        Circle().stroke(Theme.accent.opacity(0.15), lineWidth: 12)
                        Circle()
                            .trim(from: 0, to: timer.progress)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: timer.progress)
                        VStack(spacing: 4) {
                            Text(WorkoutSetFormat.duration(timer.elapsedSec))
                                .font(.system(size: 52, weight: .ultraLight, design: .rounded).monospacedDigit())
                                .foregroundStyle(timer.reachedTarget ? Theme.accent : .white)
                            if let caption = WorkoutRunnerLogic.holdCaption(target: timer.targetSec, elapsed: timer.elapsedSec) {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(timer.reachedTarget ? Theme.accent : .white.opacity(0.4))
                            }
                        }
                    }
                    .frame(width: 220, height: 220)

                    Button(action: onStop) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill").font(.system(size: 15, weight: .bold))
                            Text("Стоп").font(.body.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 48)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Theme.accent))
                    }
                    .frame(minHeight: 44)
                }
            }
            .transition(.opacity)
            .accessibilityIdentifier("hold-ring")
        }
    }
}
