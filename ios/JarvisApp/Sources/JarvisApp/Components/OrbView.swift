import SwiftUI

// MARK: – Mood

/// The emotional state of the orb — controls animation speed, particles, ripple, brightness.
enum OrbMood: Equatable {
    case heroic      // Splash — bright, slow ripple, majestic
    case welcoming   // Home/empty — soft, inviting
    case ready       // Input bar resting — responsive, waiting
    case listening   // Voice recording — fast pulse, expanding ripple
    case processing  // Jarvis thinking — accelerated ring spin
    case speaking    // TTS playing — sound waves from core
    case calm        // Profile — minimal movement
    case error       // Connection failed — dim, slow
}

// MARK: – OrbView

/// Reusable pulsing orb — the visual "heartbeat" of Jarvis.
/// Renders a Jarvis HUD-style orb using SwiftUI Canvas with concentric cyan rings/arcs.
struct OrbView: View {
    var size: CGFloat = 120
    var mood: OrbMood = .welcoming

    // MARK: - Mood targets

    private struct MoodParams {
        var rotationSpeed: Double   // base rotation multiplier
        var alpha: Double           // base opacity
        var breathAmp: Double       // core breathing amplitude
        var coreScale: Double       // core size multiplier
        var flickerAmp: Double      // brightness oscillation amplitude

        static func forMood(_ mood: OrbMood) -> MoodParams {
            switch mood {
            case .heroic:
                MoodParams(rotationSpeed: 1.0, alpha: 0.95, breathAmp: 0.08, coreScale: 1.0, flickerAmp: 0.0)
            case .welcoming:
                MoodParams(rotationSpeed: 0.8, alpha: 0.85, breathAmp: 0.06, coreScale: 1.0, flickerAmp: 0.0)
            case .ready:
                MoodParams(rotationSpeed: 1.2, alpha: 0.80, breathAmp: 0.05, coreScale: 1.0, flickerAmp: 0.0)
            case .listening:
                MoodParams(rotationSpeed: 1.6, alpha: 0.90, breathAmp: 0.12, coreScale: 1.0, flickerAmp: 0.0)
            case .processing:
                MoodParams(rotationSpeed: 3.2, alpha: 0.85, breathAmp: 0.04, coreScale: 0.9, flickerAmp: 0.15)
            case .speaking:
                MoodParams(rotationSpeed: 1.4, alpha: 0.90, breathAmp: 0.22, coreScale: 1.3, flickerAmp: 0.0)
            case .calm:
                MoodParams(rotationSpeed: 0.5, alpha: 0.60, breathAmp: 0.04, coreScale: 1.0, flickerAmp: 0.0)
            case .error:
                MoodParams(rotationSpeed: 0.3, alpha: 0.30, breathAmp: 0.02, coreScale: 0.8, flickerAmp: 0.0)
            }
        }
    }

    // MARK: - Lerped animation state

    @State private var currentSpeed: Double = 0.8
    @State private var currentAlpha: Double = 0.85
    @State private var currentBreathAmp: Double = 0.06
    @State private var currentCoreScale: Double = 1.0
    @State private var currentFlickerAmp: Double = 0.0
    @State private var lastMood: OrbMood?

    // Cyan color matching ~#54BEC4 but slightly brighter for glow
    private let cyan = Color(red: 0.33, green: 0.86, blue: 0.90)

    /// When the app isn't foreground-active, drop the per-frame
    /// `TimelineView(.animation)` (it redraws every display frame even while
    /// backgrounded/idle) and render one static frame instead.
    @Environment(\.scenePhase) private var scenePhase

    /// Fixed timestamp used to render a single static frame when the scene is
    /// not active (mirrors the `TimelineView` draw at one instant).
    private static let staticTime: Double = 0

    // MARK: - Body

    /// Per-mood redraw cadence. The Canvas rebuilds ~hundreds of glow+crisp path
    /// ops per frame on the main thread, so animating it when nothing is really
    /// moving burned ~30% CPU at idle. Active moods get 30fps; the slow-rotating
    /// resting moods get a cheap 12fps; truly at-rest moods render ONE static
    /// frame (nil → no TimelineView).
    private var animationInterval: Double? {
        switch mood {
        case .listening, .processing, .speaking: 1.0 / 30.0
        case .heroic, .welcoming, .ready: 1.0 / 12.0
        case .calm, .error: nil
        }
    }

    var body: some View {
        Group {
            if scenePhase == .active, let interval = animationInterval {
                TimelineView(.animation(minimumInterval: interval)) { timeline in
                    orbCanvas(t: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                orbCanvas(t: Self.staticTime)
            }
        }
        .frame(width: size, height: size)
        .onAppear { snapToMood() }
        .onChange(of: mood) { lerpToMood() }
    }

    @ViewBuilder
    private func orbCanvas(t: Double) -> some View {
        Canvas { context, canvasSize in
                let cx = canvasSize.width / 2
                let cy = canvasSize.height / 2
                let r = min(canvasSize.width, canvasSize.height) / 2

                let speed = currentSpeed
                let alpha = currentAlpha
                let breathAmp = currentBreathAmp
                let coreScale = currentCoreScale
                let flickerAmp = currentFlickerAmp

                // Flicker for processing mood
                let flicker = flickerAmp > 0.001
                    ? 1.0 + flickerAmp * sin(t * 17.3) * cos(t * 11.7)
                    : 1.0
                let a = alpha * flicker

                // Core breathing
                let breath = 1.0 + breathAmp * sin(t * 2.5)
                let coreR = r * 0.15 * coreScale * breath

                let center = CGPoint(x: cx, y: cy)

                // --- 1. Core glow (radial gradient) ---
                drawCoreGlow(context: &context, center: center, coreR: coreR, alpha: a)

                // --- 2. Innermost arc (r=0.27): partial arc ~250 deg, thin ---
                drawArc(context: &context, center: center, radius: r * 0.27,
                        startDeg: 0, sweepDeg: 250,
                        rotation: t * speed * 0.6,
                        lineWidth: 1.2, alpha: a * 0.7)

                // --- 3. Inner thin circle (r=0.34): full circle + 20 tick marks ---
                drawFullCircle(context: &context, center: center, radius: r * 0.34,
                               lineWidth: 0.6, alpha: a * 0.35)
                drawTicks(context: &context, center: center, radius: r * 0.34,
                          count: 20, tickLength: r * 0.025, lineWidth: 0.8,
                          rotation: t * speed * -0.3, alpha: a * 0.5)

                // --- 4. Inner thick band (r=0.46): two half-arcs with gap ---
                drawArc(context: &context, center: center, radius: r * 0.46,
                        startDeg: 10, sweepDeg: 160,
                        rotation: t * speed * 0.9,
                        lineWidth: 5, alpha: a * 0.55)
                drawArc(context: &context, center: center, radius: r * 0.46,
                        startDeg: 190, sweepDeg: 150,
                        rotation: t * speed * 0.9,
                        lineWidth: 5, alpha: a * 0.50)

                // --- 5. Thin bright ring (r=0.58): ~300 deg arc + 24 dots ---
                drawArc(context: &context, center: center, radius: r * 0.58,
                        startDeg: 20, sweepDeg: 300,
                        rotation: t * speed * -0.7,
                        lineWidth: 1.0, alpha: a * 0.65)
                drawDots(context: &context, center: center, radius: r * 0.58,
                         count: 24, dotRadius: r * 0.007,
                         rotation: t * speed * -0.7, alpha: a * 0.5)

                // --- 6. Medium arcs (r=0.71): 3 segments ~100 deg + 36 ticks at r=0.67 ---
                for i in 0..<3 {
                    let startDeg = Double(i) * 120.0 + 5.0
                    drawArc(context: &context, center: center, radius: r * 0.71,
                            startDeg: startDeg, sweepDeg: 100,
                            rotation: t * speed * 1.1,
                            lineWidth: 2.5, alpha: a * 0.55)
                }
                drawTicks(context: &context, center: center, radius: r * 0.67,
                          count: 36, tickLength: r * 0.03, lineWidth: 0.7,
                          rotation: t * speed * 1.1, alpha: a * 0.4)

                // --- 7. Thick band (r=0.84): 4 segments ~80 deg ---
                for i in 0..<4 {
                    let startDeg = Double(i) * 90.0 + 5.0
                    drawArc(context: &context, center: center, radius: r * 0.84,
                            startDeg: startDeg, sweepDeg: 80,
                            rotation: t * speed * -0.5,
                            lineWidth: 4, alpha: a * 0.45)
                }

                // --- 8. Outer arcs (r=0.96): two large arcs + 60 ticks at r=0.94 ---
                drawArc(context: &context, center: center, radius: r * 0.96,
                        startDeg: 5, sweepDeg: 170,
                        rotation: t * speed * 0.4,
                        lineWidth: 2.0, alpha: a * 0.5)
                drawArc(context: &context, center: center, radius: r * 0.96,
                        startDeg: 185, sweepDeg: 165,
                        rotation: t * speed * 0.4,
                        lineWidth: 2.0, alpha: a * 0.5)
                drawTicks(context: &context, center: center, radius: r * 0.94,
                          count: 60, tickLength: r * 0.02, lineWidth: 0.5,
                          rotation: t * speed * 0.4, alpha: a * 0.35)

                // --- 9. Outermost thin ring (r=1.03): full circle ---
                drawFullCircle(context: &context, center: center, radius: r * 1.03,
                               lineWidth: 0.5, alpha: a * 0.25)
            }
    }

    // MARK: - Drawing helpers

    private func drawCoreGlow(context: inout GraphicsContext, center: CGPoint, coreR: Double, alpha: Double) {
        // Outer soft glow
        let outerGlowR = coreR * 3.5
        let outerGlow = Path(ellipseIn: CGRect(
            x: center.x - outerGlowR, y: center.y - outerGlowR,
            width: outerGlowR * 2, height: outerGlowR * 2))
        context.fill(outerGlow, with: .radialGradient(
            Gradient(colors: [
                cyan.opacity(alpha * 0.25),
                cyan.opacity(alpha * 0.08),
                cyan.opacity(0)
            ]),
            center: center,
            startRadius: 0,
            endRadius: outerGlowR
        ))

        // Bright core
        let corePath = Path(ellipseIn: CGRect(
            x: center.x - coreR, y: center.y - coreR,
            width: coreR * 2, height: coreR * 2))
        context.fill(corePath, with: .radialGradient(
            Gradient(colors: [
                Color.white.opacity(alpha * 0.9),
                cyan.opacity(alpha * 0.7),
                cyan.opacity(alpha * 0.15),
                cyan.opacity(0)
            ]),
            center: center,
            startRadius: 0,
            endRadius: coreR
        ))
    }

    private func drawArc(context: inout GraphicsContext, center: CGPoint, radius: Double,
                         startDeg: Double, sweepDeg: Double, rotation: Double,
                         lineWidth: Double, alpha: Double) {
        let rotRad = rotation * .pi / 180.0 * 20.0  // scale rotation speed
        let startRad = (startDeg + rotRad * 180.0 / .pi) * .pi / 180.0
        let endRad = startRad + sweepDeg * .pi / 180.0

        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .radians(startRad), endAngle: .radians(endRad),
                    clockwise: false)

        // Glow layer
        context.stroke(path,
                       with: .color(cyan.opacity(alpha * 0.3)),
                       style: StrokeStyle(lineWidth: lineWidth + 4, lineCap: .round))

        // Crisp layer
        context.stroke(path,
                       with: .color(cyan.opacity(alpha)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private func drawFullCircle(context: inout GraphicsContext, center: CGPoint,
                                radius: Double, lineWidth: Double, alpha: Double) {
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))

        // Glow
        context.stroke(path,
                       with: .color(cyan.opacity(alpha * 0.25)),
                       style: StrokeStyle(lineWidth: lineWidth + 3))
        // Crisp
        context.stroke(path,
                       with: .color(cyan.opacity(alpha)),
                       style: StrokeStyle(lineWidth: lineWidth))
    }

    private func drawTicks(context: inout GraphicsContext, center: CGPoint,
                           radius: Double, count: Int, tickLength: Double,
                           lineWidth: Double, rotation: Double, alpha: Double) {
        let rotRad = rotation * .pi / 180.0 * 20.0
        let angleStep = (2.0 * .pi) / Double(count)

        for i in 0..<count {
            let angle = Double(i) * angleStep + rotRad
            let innerR = radius - tickLength / 2
            let outerR = radius + tickLength / 2
            let cosA = cos(angle)
            let sinA = sin(angle)

            var tick = Path()
            tick.move(to: CGPoint(x: center.x + innerR * cosA, y: center.y + innerR * sinA))
            tick.addLine(to: CGPoint(x: center.x + outerR * cosA, y: center.y + outerR * sinA))

            context.stroke(tick,
                           with: .color(cyan.opacity(alpha)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        }
    }

    private func drawDots(context: inout GraphicsContext, center: CGPoint,
                          radius: Double, count: Int, dotRadius: Double,
                          rotation: Double, alpha: Double) {
        let rotRad = rotation * .pi / 180.0 * 20.0
        let angleStep = (2.0 * .pi) / Double(count)

        for i in 0..<count {
            let angle = Double(i) * angleStep + rotRad
            let dx = center.x + radius * cos(angle)
            let dy = center.y + radius * sin(angle)

            let dot = Path(ellipseIn: CGRect(
                x: dx - dotRadius, y: dy - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2))

            // Glow
            context.fill(dot, with: .color(cyan.opacity(alpha * 0.4)))
            // Crisp (slightly smaller visual via same path but brighter)
            context.fill(dot, with: .color(cyan.opacity(alpha)))
        }
    }

    // MARK: - Mood lerping

    private func snapToMood() {
        let p = MoodParams.forMood(mood)
        currentSpeed = p.rotationSpeed
        currentAlpha = p.alpha
        currentBreathAmp = p.breathAmp
        currentCoreScale = p.coreScale
        currentFlickerAmp = p.flickerAmp
        lastMood = mood
    }

    private func lerpToMood() {
        let p = MoodParams.forMood(mood)
        withAnimation(.easeInOut(duration: 0.6)) {
            currentSpeed = p.rotationSpeed
            currentAlpha = p.alpha
            currentBreathAmp = p.breathAmp
            currentCoreScale = p.coreScale
            currentFlickerAmp = p.flickerAmp
        }
        lastMood = mood
    }
}

// MARK: – Backward compatibility

extension OrbView {
    /// Legacy convenience init — maps brightness to a mood automatically.
    init(size: CGFloat = 120, brightness: Double) {
        self.size = size
        if brightness >= 0.9 {
            self.mood = .welcoming
        } else if brightness >= 0.5 {
            self.mood = .calm
        } else {
            self.mood = .error
        }
    }
}
