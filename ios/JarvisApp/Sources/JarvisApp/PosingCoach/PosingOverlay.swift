// Sources/JarvisApp/PosingCoach/PosingOverlay.swift
import SwiftUI

struct PosingOverlay: View {
    let hints: [Hint]
    /// Device roll off level, degrees ∈ [-45, 45], for the horizon indicator.
    var tiltDegrees: Double = 0

    private static let levelGreen = Color(red: 0.24, green: 0.86, blue: 0.52)
    private var isLevel: Bool { abs(tiltDegrees) <= CompositionEngine.tiltThresholdDegrees }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Path { p in
                    let w = geo.size.width, h = geo.size.height
                    for f in [1.0/3, 2.0/3] {
                        p.move(to: CGPoint(x: w*f, y: 0)); p.addLine(to: CGPoint(x: w*f, y: h))
                        p.move(to: CGPoint(x: 0, y: h*f)); p.addLine(to: CGPoint(x: w, y: h*f))
                    }
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
            }

            // Horizon level indicator: fixed reference tick + a line that rolls with the
            // device. When level, the line is horizontal, green, and covers the reference.
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 44, height: 2)
                Rectangle()
                    .fill(isLevel ? Self.levelGreen : Color.white.opacity(0.85))
                    .frame(width: 150, height: 2)
                    .rotationEffect(.degrees(-tiltDegrees))
                    .animation(.linear(duration: 0.08), value: tiltDegrees)
            }
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    ForEach(hints, id: \.code) { hint in
                        Text(hint.text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(hint.severity == .warn ? Color(red: 1, green: 0.72, blue: 0.3)
                                                               : Color(red: 0.24, green: 0.86, blue: 0.52),
                                        in: Capsule())
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .allowsHitTesting(false)
    }
}
