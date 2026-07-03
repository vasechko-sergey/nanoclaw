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

/// E: a wrist hugging the torso (near its hip's x) → create a gap / hand on hip.
public struct ArmsGapRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        let gap: CGFloat = 0.06
        if let lw = s.point(.leftWrist)?.position, let lh = s.point(.leftHip)?.position,
           abs(lw.x - lh.x) < gap {
            return PoseSuggestion(code: "arms.gap", text: "Оторви руки — рука на бедро или к ключице",
                                  priority: 4, targetDeltas: [.leftWrist: CGPoint(x: lw.x - 0.09, y: lw.y)],
                                  changedJoints: [.leftWrist])
        }
        if let rw = s.point(.rightWrist)?.position, let rh = s.point(.rightHip)?.position,
           abs(rw.x - rh.x) < gap {
            return PoseSuggestion(code: "arms.gap", text: "Оторви руки — рука на бедро или к ключице",
                                  priority: 4, targetDeltas: [.rightWrist: CGPoint(x: rw.x + 0.09, y: rw.y)],
                                  changedJoints: [.rightWrist])
        }
        return nil
    }
}

/// F: a straight, near-vertical arm (shoulder-elbow-wrist in a line) → bend the elbow.
public struct ElbowBendRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        func straightVertical(_ sh: CGPoint, _ el: CGPoint, _ wr: CGPoint) -> Bool {
            PoseGeometry.angle(sh, el, wr) > straightAngle
                && abs(sh.x - wr.x) < 0.05 && wr.y > sh.y
        }
        if let sh = s.point(.leftShoulder)?.position, let el = s.point(.leftElbow)?.position,
           let wr = s.point(.leftWrist)?.position, straightVertical(sh, el, wr) {
            return PoseSuggestion(code: "elbow.bend", text: "Согни локоть, смени угол",
                                  priority: 5, targetDeltas: [.leftElbow: CGPoint(x: el.x - 0.06, y: el.y)],
                                  changedJoints: [.leftElbow])
        }
        if let sh = s.point(.rightShoulder)?.position, let el = s.point(.rightElbow)?.position,
           let wr = s.point(.rightWrist)?.position, straightVertical(sh, el, wr) {
            return PoseSuggestion(code: "elbow.bend", text: "Согни локоть, смени угол",
                                  priority: 5, targetDeltas: [.rightElbow: CGPoint(x: el.x + 0.06, y: el.y)],
                                  changedJoints: [.rightElbow])
        }
        return nil
    }
}

/// G (gentle): short apparent neck (chin up / head sunk) → elongate neck.
public struct ChinNeckRule: PoseRule {
    public init() {}
    static let neckRatioThreshold: CGFloat = 0.35
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        guard let nose = s.point(.nose)?.position,
              let ls = s.point(.leftShoulder)?.position, let rs = s.point(.rightShoulder)?.position,
              let lh = s.point(.leftHip)?.position, let rh = s.point(.rightHip)?.position
        else { return nil }
        let shMidY = (ls.y + rs.y) / 2
        let hipMidY = (lh.y + rh.y) / 2
        let torso = hipMidY - shMidY          // > 0: shoulders above hips
        let neck = shMidY - nose.y            // > 0: nose above shoulders
        guard torso > 0.05, neck / torso < Self.neckRatioThreshold else { return nil }
        return PoseSuggestion(code: "chin.neck", text: "Чуть опусти подбородок, вытяни шею",
                              priority: 6, targetDeltas: [.nose: CGPoint(x: nose.x, y: nose.y - 0.03)],
                              changedJoints: [.nose])
    }
}
