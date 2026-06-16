import SwiftUI

/// Simplified orb for small sizes (input bar button, badges).
/// 3 layers instead of 9: core glow + inner arc + outer arc.
/// Same mood system and cyan palette as the full OrbView.
struct MiniOrbView: View {
    var size: CGFloat = 36
    var mood: OrbMood = .calm

    /// When the app isn't foreground-active, drop the per-frame
    /// `TimelineView(.animation)` (it redraws every display frame even while
    /// backgrounded/idle) and render one static frame instead.
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Mood params (subset of OrbView)

    private struct Params {
        var speed: Double
        var alpha: Double
        var breathAmp: Double

        static func forMood(_ mood: OrbMood) -> Params {
            switch mood {
            case .heroic:     Params(speed: 1.0, alpha: 0.95, breathAmp: 0.10)
            case .welcoming:  Params(speed: 0.8, alpha: 0.85, breathAmp: 0.08)
            case .ready:      Params(speed: 1.2, alpha: 0.80, breathAmp: 0.06)
            case .listening:  Params(speed: 2.0, alpha: 0.95, breathAmp: 0.18)
            case .processing: Params(speed: 3.0, alpha: 0.85, breathAmp: 0.05)
            case .speaking:   Params(speed: 1.4, alpha: 0.90, breathAmp: 0.20)
            case .calm:       Params(speed: 0.5, alpha: 0.65, breathAmp: 0.05)
            case .error:      Params(speed: 0.3, alpha: 0.30, breathAmp: 0.02)
            }
        }
    }

    @State private var curSpeed: Double = 0.5
    @State private var curAlpha: Double = 0.65
    @State private var curBreathAmp: Double = 0.05

    private let cyan = Color(red: 0.33, green: 0.86, blue: 0.90)

    @State private var pulseScale: CGFloat = 1.0

    private var isListening: Bool {
        mood == .listening || mood == .speaking
    }

    var body: some View {
        ZStack {
            // Pulsing ring when recording
            if isListening {
                Circle()
                    .stroke(cyan.opacity(0.5), lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(pulseScale)
                    .opacity(2.0 - Double(pulseScale))
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                            pulseScale = 2.0
                        }
                    }
                    .onDisappear {
                        pulseScale = 1.0
                    }
            }

            // Main orb. While foreground-active, animate via TimelineView;
            // otherwise render one static frame so we stop redrawing every
            // display frame when backgrounded/idle. Visuals are identical
            // while active.
            if scenePhase == .active {
                TimelineView(.animation) { timeline in
                    orbCanvas(t: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                orbCanvas(t: Self.staticTime)
            }

            // Particle overlay: 3 dots rotating around the orb, only for .processing at size >= 20
            if size >= 20 && mood == .processing {
                if scenePhase == .active {
                    TimelineView(.animation) { timeline in
                        particleCanvas(t: timeline.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    particleCanvas(t: Self.staticTime)
                }
            }
        }
        .onAppear { snap() }
        .onChange(of: mood) { lerp() }
    }

    /// Fixed timestamp used to render a single static frame when the scene is
    /// not active (mirrors the `TimelineView` draw at one instant).
    private static let staticTime: Double = 0

    @ViewBuilder
    private func orbCanvas(t: Double) -> some View {
        Canvas { ctx, sz in
            let cx = sz.width / 2
            let cy = sz.height / 2
            let r = min(sz.width, sz.height) / 2

            let a = curAlpha
            let breath = 1.0 + curBreathAmp * sin(t * 2.5)
            let center = CGPoint(x: cx, y: cy)

            // 1. Core glow
            let coreR = r * 0.22 * breath
            let glowR = coreR * 3.0
            let glowPath = Path(ellipseIn: CGRect(
                x: cx - glowR, y: cy - glowR,
                width: glowR * 2, height: glowR * 2))
            ctx.fill(glowPath, with: .radialGradient(
                Gradient(colors: [
                    cyan.opacity(a * 0.35),
                    cyan.opacity(a * 0.10),
                    cyan.opacity(0)
                ]),
                center: center, startRadius: 0, endRadius: glowR
            ))
            let corePath = Path(ellipseIn: CGRect(
                x: cx - coreR, y: cy - coreR,
                width: coreR * 2, height: coreR * 2))
            ctx.fill(corePath, with: .radialGradient(
                Gradient(colors: [
                    Color.white.opacity(a * 0.9),
                    cyan.opacity(a * 0.6),
                    cyan.opacity(0)
                ]),
                center: center, startRadius: 0, endRadius: coreR
            ))

            // 2. Inner arc (r=0.45): ~240 deg
            drawArc(ctx: &ctx, center: center, radius: r * 0.45,
                    startDeg: 0, sweepDeg: 240,
                    rotation: t * curSpeed * 0.8,
                    lineWidth: 1.5, alpha: a * 0.7)

            // 3. Outer arcs (r=0.78): two segments ~140 deg each
            drawArc(ctx: &ctx, center: center, radius: r * 0.78,
                    startDeg: 10, sweepDeg: 140,
                    rotation: t * curSpeed * -0.6,
                    lineWidth: 2.5, alpha: a * 0.55)
            drawArc(ctx: &ctx, center: center, radius: r * 0.78,
                    startDeg: 190, sweepDeg: 130,
                    rotation: t * curSpeed * -0.6,
                    lineWidth: 2.5, alpha: a * 0.50)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func particleCanvas(t: Double) -> some View {
        let angle = t * curSpeed * 1.5
        let orbit = size / 2 + 4

        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let phase = angle + Double(i) * (2 * .pi / 3)
                Circle()
                    .fill(cyan.opacity(0.7))
                    .frame(width: 2.5, height: 2.5)
                    .offset(x: cos(phase) * orbit, y: sin(phase) * orbit)
            }
        }
        .frame(width: size + 12, height: size + 12)
    }

    // MARK: - Drawing

    private func drawArc(ctx: inout GraphicsContext, center: CGPoint, radius: Double,
                         startDeg: Double, sweepDeg: Double, rotation: Double,
                         lineWidth: Double, alpha: Double) {
        let rotRad = rotation * .pi / 180.0 * 20.0
        let startRad = (startDeg + rotRad * 180.0 / .pi) * .pi / 180.0
        let endRad = startRad + sweepDeg * .pi / 180.0

        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .radians(startRad), endAngle: .radians(endRad),
                    clockwise: false)

        // Glow
        ctx.stroke(path, with: .color(cyan.opacity(alpha * 0.3)),
                   style: StrokeStyle(lineWidth: lineWidth + 3, lineCap: .round))
        // Crisp
        ctx.stroke(path, with: .color(cyan.opacity(alpha)),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    // MARK: - Mood

    private func snap() {
        let p = Params.forMood(mood)
        curSpeed = p.speed; curAlpha = p.alpha; curBreathAmp = p.breathAmp
    }

    private func lerp() {
        let p = Params.forMood(mood)
        withAnimation(.easeInOut(duration: 0.5)) {
            curSpeed = p.speed; curAlpha = p.alpha; curBreathAmp = p.breathAmp
        }
    }
}
