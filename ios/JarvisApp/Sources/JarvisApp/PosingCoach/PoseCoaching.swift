// Sources/JarvisApp/PosingCoach/PoseCoaching.swift
import CoreGraphics

/// One pose correction a rule wants to make.
public struct PoseSuggestion: Equatable {
    public let code: String
    public let text: String
    /// Lower = higher priority (surfaced first).
    public let priority: Int
    /// Absolute target positions (screen space) for the joints this rule moves.
    public let targetDeltas: [BodyJoint: CGPoint]
    /// Joints that changed — arrows are drawn current → target for these.
    public let changedJoints: [BodyJoint]
    public init(code: String, text: String, priority: Int,
                targetDeltas: [BodyJoint: CGPoint], changedJoints: [BodyJoint]) {
        self.code = code; self.text = text; self.priority = priority
        self.targetDeltas = targetDeltas; self.changedJoints = changedJoints
    }
}

/// A pure posing heuristic over a 2D skeleton. Returns nil when it doesn't apply
/// or its required joints aren't present (detector already confidence-filters).
public protocol PoseRule {
    func evaluate(_ s: Skeleton) -> PoseSuggestion?
}

/// Aggregated coaching output for one frame.
public struct PoseGuidance {
    public let hints: [Hint]
    public let ghost: Skeleton?
    public let arrows: [(CGPoint, CGPoint)]
    public init(hints: [Hint], ghost: Skeleton?, arrows: [(CGPoint, CGPoint)]) {
        self.hints = hints; self.ghost = ghost; self.arrows = arrows
    }
}

public enum PoseCoach {
    public static let rules: [PoseRule] = [
        WeightShiftRule(), KneeBendRule(), FeetStaggerRule(),
        BodyAngleRule(), ArmsGapRule(), ElbowBendRule(),
    ]
    public static let maxSuggestions = 2

    /// Only coach when a standing body is framed (hips + at least one knee visible).
    public static func standingBody(_ s: Skeleton) -> Bool {
        let hips = s.point(.leftHip) != nil || s.point(.rightHip) != nil
        let knees = s.point(.leftKnee) != nil || s.point(.rightKnee) != nil
        return hips && knees
    }

    public static func guide(_ s: Skeleton) -> PoseGuidance {
        guard standingBody(s) else { return PoseGuidance(hints: [], ghost: nil, arrows: []) }
        let picked = rules.compactMap { $0.evaluate(s) }
            .sorted { $0.priority < $1.priority }
            .prefix(maxSuggestions)
        guard !picked.isEmpty else { return PoseGuidance(hints: [], ghost: nil, arrows: []) }
        var deltas: [BodyJoint: CGPoint] = [:]
        var changed: [BodyJoint] = []
        var hints: [Hint] = []
        for sug in picked {
            hints.append(Hint(kind: .pose, severity: .info, text: sug.text, code: sug.code))
            for (j, p) in sug.targetDeltas { deltas[j] = p }
            changed.append(contentsOf: sug.changedJoints)
        }
        let ghost = applyDeltas(s, deltas)
        let arrows: [(CGPoint, CGPoint)] = changed.compactMap { j in
            guard let from = s.point(j)?.position, let to = deltas[j] else { return nil }
            return (from, to)
        }
        return PoseGuidance(hints: hints, ghost: ghost, arrows: arrows)
    }

    /// Return a copy of `base` with the given joints moved to their target positions.
    public static func applyDeltas(_ base: Skeleton, _ deltas: [BodyJoint: CGPoint]) -> Skeleton {
        var joints = base.joints
        for (j, p) in deltas {
            let conf = base.joints[j]?.confidence ?? 1
            joints[j] = JointPoint(position: p, confidence: conf)
        }
        return Skeleton(joints: joints)
    }
}
