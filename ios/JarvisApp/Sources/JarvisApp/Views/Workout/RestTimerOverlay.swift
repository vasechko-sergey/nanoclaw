import SwiftUI

struct RestTimerOverlay: View {
    @ObservedObject var timer: RestTimer

    var body: some View {
        if timer.running {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                VStack(spacing: 20) {
                    Text("Отдых")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(formatted(timer.remainingSec))
                        .font(.system(size: 84, weight: .ultraLight, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Button {
                        timer.skip()
                    } label: {
                        Text("пропустить")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(.white.opacity(0.12)))
                            .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                    }
                    .frame(minHeight: 44)
                }
            }
            .transition(.opacity)
        }
    }

    private func formatted(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return String(format: "%d:%02d", m, s)
    }
}
