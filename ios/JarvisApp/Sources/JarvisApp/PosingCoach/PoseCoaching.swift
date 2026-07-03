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
