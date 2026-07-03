// Sources/JarvisApp/PosingCoach/PoseGeometry.swift
import CoreGraphics
import Foundation

enum PoseGeometry {
    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
    /// Interior angle at `vertex` between vertex→a and vertex→b, degrees in [0, 180].
    static func angle(_ a: CGPoint, _ vertex: CGPoint, _ b: CGPoint) -> CGFloat {
        let v1 = CGVector(dx: a.x - vertex.x, dy: a.y - vertex.y)
        let v2 = CGVector(dx: b.x - vertex.x, dy: b.y - vertex.y)
        let dot = v1.dx * v2.dx + v1.dy * v2.dy
        let m1 = hypot(v1.dx, v1.dy), m2 = hypot(v2.dx, v2.dy)
        guard m1 > 0, m2 > 0 else { return 180 }
        let cos = max(-1, min(1, dot / (m1 * m2)))
        return acos(cos) * 180 / .pi
    }
}
