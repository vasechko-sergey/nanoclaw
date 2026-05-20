import SwiftUI

struct JarvisRingView: View {
    let size: CGFloat
    private let startDate = Date()

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(startDate)
            Canvas { ctx, sz in
                drawRing(ctx, sz, t)
            }
        }
        .frame(width: size, height: size)
    }

    private func drawRing(_ ctx: GraphicsContext, _ sz: CGSize, _ t: Double) {
        let cx = sz.width / 2, cy = sz.height / 2
        let R = min(sz.width, sz.height) * 0.38
        let teal = Color(red: 0, green: 0.82, blue: 0.75)
        let bright = Color(red: 0.5, green: 1.0, blue: 0.92)

        // Outer particle ring
        let n = 220
        for i in 0..<n {
            let u = Double(i) / Double(n) * .pi * 2
            let wave = sin(u * 3 + t * 1.8) * 0.14 + sin(u * 5 - t * 1.1) * 0.07
            let r = R * (1 + wave)
            let x = cx + cos(u) * r
            let depth = sin(u)
            let y = cy + depth * r * 0.38
            let alpha = (depth + 1.5) / 2.5
            let ps = (depth + 1) / 2 * 2.5 + 0.6
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - ps / 2, y: y - ps / 2, width: ps, height: ps)),
                with: .color(teal.opacity(alpha))
            )
        }

        // Inner ring (offset phase)
        let n2 = 140
        for i in 0..<n2 {
            let u = Double(i) / Double(n2) * .pi * 2
            let wave = sin(u * 4 - t * 2.1) * 0.09 + sin(u * 6 + t * 0.9) * 0.05
            let r = R * (0.82 + wave)
            let x = cx + cos(u) * r
            let depth = sin(u)
            let y = cy + depth * r * 0.33
            let alpha = (depth + 1.5) / 2.5 * 0.55
            let ps = 1.0
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - ps / 2, y: y - ps / 2, width: ps, height: ps)),
                with: .color(bright.opacity(alpha))
            )
        }

        // Center ellipse
        let cr = R * 0.2
        var oval = Path()
        oval.addEllipse(in: CGRect(x: cx - cr, y: cy - cr * 0.5, width: cr * 2, height: cr))
        ctx.stroke(oval, with: .color(teal.opacity(0.45)), lineWidth: 0.7)

        // Center dot
        let dr = R * 0.045
        ctx.fill(Path(ellipseIn: CGRect(x: cx - dr, y: cy - dr, width: dr * 2, height: dr * 2)),
                 with: .color(teal.opacity(0.9)))
    }
}
