// Sources/JarvisApp/PosingCoach/PosingOverlay.swift
import SwiftUI

struct PosingOverlay: View {
    let hints: [Hint]
    /// Deviation from level ∈ [-45, 45] — decides whether the horizon line shows.
    var tiltDegrees: Double = 0
    /// Raw portrait-relative roll ∈ (-180, 180] — orients the line along the true horizon.
    var rollDegrees: Double = 0

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

            // Horizon level indicator (stock-camera style): a green line that appears only
            // when you're within the level tolerance, oriented along the true horizon via
            // raw roll — so it lies horizontal in the user's view in ANY device orientation
            // (the UI is portrait-locked, so we can't rely on UI-space "horizontal").
            // Beyond tolerance the line hides and the "Выровняй горизонт" text hint takes over.
            if isLevel {
                Rectangle()
                    .fill(Self.levelGreen)
                    .frame(width: 160, height: 2)
                    .rotationEffect(.degrees(-rollDegrees))
                    .animation(.linear(duration: 0.08), value: rollDegrees)
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
