// Sources/JarvisApp/PosingCoach/PoseRules.swift
import CoreGraphics

// Shared thresholds (normalized screen space).
private let levelTol: CGFloat = 0.03      // "level" y-difference
private let straightAngle: CGFloat = 165  // knee/elbow angle counted as straight (deg)

/// A: legs straight + hips level → shift weight to the far leg (creates the S-curve).
public struct WeightShiftRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        guard let lh = s.point(.leftHip)?.position, let rh = s.point(.rightHip)?.position,
              let lk = s.point(.leftKnee)?.position, let rk = s.point(.rightKnee)?.position,
              let la = s.point(.leftAnkle)?.position, let ra = s.point(.rightAnkle)?.position,
              let ls = s.point(.leftShoulder)?.position, let rs = s.point(.rightShoulder)?.position
        else { return nil }
        let hipsLevel = abs(lh.y - rh.y) < levelTol
        let legsStraight = PoseGeometry.angle(lh, lk, la) > straightAngle
            && PoseGeometry.angle(rh, rk, ra) > straightAngle
        guard hipsLevel && legsStraight else { return nil }
        let tilt: CGFloat = 0.04
        let deltas: [BodyJoint: CGPoint] = [
            .leftHip: CGPoint(x: lh.x, y: lh.y + tilt),
            .rightHip: CGPoint(x: rh.x, y: rh.y - tilt),
            .leftShoulder: CGPoint(x: ls.x, y: ls.y - tilt * 0.5),
            .rightShoulder: CGPoint(x: rs.x, y: rs.y + tilt * 0.5),
        ]
        return PoseSuggestion(code: "weight.shift", text: "Перенеси вес на дальнюю ногу",
                              priority: 0, targetDeltas: deltas,
                              changedJoints: [.leftHip, .rightHip, .leftShoulder, .rightShoulder])
    }
}

/// B: both legs straight → bend the near (model's-left) knee. Pairs with A.
public struct KneeBendRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        guard let lh = s.point(.leftHip)?.position, let rh = s.point(.rightHip)?.position,
              let lk = s.point(.leftKnee)?.position, let rk = s.point(.rightKnee)?.position,
              let la = s.point(.leftAnkle)?.position, let ra = s.point(.rightAnkle)?.position
        else { return nil }
        let legsStraight = PoseGeometry.angle(lh, lk, la) > straightAngle
            && PoseGeometry.angle(rh, rk, ra) > straightAngle
        guard legsStraight else { return nil }
        let hipsMidX = (lh.x + rh.x) / 2
        // Push the near knee toward center + slightly up → a soft bend.
        let target = CGPoint(x: lk.x + (hipsMidX - lk.x) * 0.4, y: lk.y - 0.02)
        return PoseSuggestion(code: "knee.bend", text: "Согни ближнее колено",
                              priority: 1, targetDeltas: [.leftKnee: target],
                              changedJoints: [.leftKnee])
    }
}

/// C: ankles side by side (same level, close in x) → stagger one foot forward.
public struct FeetStaggerRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        guard let la = s.point(.leftAnkle)?.position, let ra = s.point(.rightAnkle)?.position
        else { return nil }
        let sameLevel = abs(la.y - ra.y) < 0.02
        let close = abs(la.x - ra.x) < 0.12
        guard sameLevel && close else { return nil }
        let target = CGPoint(x: la.x - 0.04, y: la.y + 0.03) // forward + slightly lower
        return PoseSuggestion(code: "feet.stagger", text: "Одну ногу чуть вперёд",
                              priority: 2, targetDeltas: [.leftAnkle: target],
                              changedJoints: [.leftAnkle])
    }
}

/// D: shoulders square to camera (wide + level) → turn to a 3/4 angle.
public struct BodyAngleRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        guard let ls = s.point(.leftShoulder)?.position, let rs = s.point(.rightShoulder)?.position,
              let lh = s.point(.leftHip)?.position, let rh = s.point(.rightHip)?.position
        else { return nil }
        let shoulderW = abs(ls.x - rs.x)
        let hipW = abs(lh.x - rh.x)
        let shouldersLevel = abs(ls.y - rs.y) < levelTol
        let torsoH = abs(PoseGeometry.midpoint(ls, rs).y - PoseGeometry.midpoint(lh, rh).y)
        let facingFront = shoulderW > max(hipW, torsoH * 0.5) && shouldersLevel
        guard facingFront else { return nil }
        let cx = PoseGeometry.midpoint(ls, rs).x
        // Narrow the shoulder line: pull the right shoulder toward center (and left a touch).
        let deltas: [BodyJoint: CGPoint] = [
            .rightShoulder: CGPoint(x: rs.x + (cx - rs.x) * 0.35, y: rs.y),
            .leftShoulder: CGPoint(x: ls.x + (cx - ls.x) * 0.15, y: ls.y),
        ]
        return PoseSuggestion(code: "body.angle", text: "Развернись на ¾ к камере",
                              priority: 3, targetDeltas: deltas,
                              changedJoints: [.rightShoulder, .leftShoulder])
    }
}
