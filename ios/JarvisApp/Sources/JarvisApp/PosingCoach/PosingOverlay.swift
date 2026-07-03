// Sources/JarvisApp/PosingCoach/PosingOverlay.swift
import SwiftUI

struct PosingOverlay: View {
    let hints: [Hint]
    /// Deviation from level ∈ [-45, 45] — decides whether the horizon line shows.
    var tiltDegrees: Double = 0
    /// Raw portrait-relative roll ∈ (-180, 180] — orients the line along the true horizon.
    var rollDegrees: Double = 0
    /// Ghost target pose to draw (nil = none).
    var ghost: Skeleton? = nil
    /// Arrows current → target (normalized points).
    var arrows: [(CGPoint, CGPoint)] = []

    private static let bones: [(BodyJoint, BodyJoint)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.neck, .nose),
    ]
    private static let ghostBlue = Color(red: 0.48, green: 0.63, blue: 1.0)

    private static let levelGreen = Color(red: 0.24, green: 0.86, blue: 0.52)
    /// Tight window where the horizon counts as truly level (line turns green).
    private static let levelTolerance = 1.0
    /// Show the line to help you level within the working band; green only when exact.
    private var showLine: Bool { abs(tiltDegrees) <= CompositionEngine.tiltThresholdDegrees }
    private var isLevel: Bool { abs(tiltDegrees) <= Self.levelTolerance }

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
            if showLine {
                Rectangle()
                    .fill(isLevel ? Self.levelGreen : Color.white.opacity(0.85))
                    .frame(width: 160, height: 2)
                    .rotationEffect(.degrees(-rollDegrees))
                    .animation(.linear(duration: 0.08), value: rollDegrees)
            }

            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                if let ghost {
                    Path { p in
                        for (a, b) in Self.bones {
                            guard let pa = ghost.point(a)?.position, let pb = ghost.point(b)?.position else { continue }
                            p.move(to: CGPoint(x: pa.x * w, y: pa.y * h))
                            p.addLine(to: CGPoint(x: pb.x * w, y: pb.y * h))
                        }
                    }
                    .stroke(Self.ghostBlue, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 4]))
                    .opacity(0.9)
                }
                ForEach(Array(arrows.enumerated()), id: \.offset) { _, seg in
                    Path { p in
                        p.move(to: CGPoint(x: seg.0.x * w, y: seg.0.y * h))
                        p.addLine(to: CGPoint(x: seg.1.x * w, y: seg.1.y * h))
                    }
                    .stroke(Self.ghostBlue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
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
