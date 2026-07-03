import CoreGraphics

/// Per-joint exponential smoothing of a skeleton across frames — steadies the
/// ghost + rule firing against raw Vision jitter. Stateful; one per screen.
public final class SkeletonSmoother {
    private let alpha: CGFloat
    private var prev: [BodyJoint: CGPoint] = [:]
    public init(alpha: CGFloat = 0.35) { self.alpha = alpha }

    public func smooth(_ s: Skeleton?) -> Skeleton? {
        guard let s else { prev = [:]; return nil }
        var out: [BodyJoint: JointPoint] = [:]
        var next: [BodyJoint: CGPoint] = [:]
        for (j, jp) in s.joints {
            let p: CGPoint
            if let pr = prev[j] {
                p = CGPoint(x: pr.x + alpha * (jp.position.x - pr.x),
                            y: pr.y + alpha * (jp.position.y - pr.y))
            } else { p = jp.position }
            next[j] = p
            out[j] = JointPoint(position: p, confidence: jp.confidence)
        }
        prev = next
        return Skeleton(joints: out)
    }

    public func reset() { prev = [:] }
}
