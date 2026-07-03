// Sources/JarvisApp/PosingCoach/PosingTypes.swift
import CoreGraphics

/// Body joints we care about. Subset of Vision's VNHumanBodyPoseObservation.JointName.
public enum BodyJoint: String, CaseIterable {
    case nose, neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
    case root
}

/// One detected joint in normalized SCREEN space:
/// x,y in [0,1], origin top-left, y increases downward.
public struct JointPoint: Equatable {
    public let position: CGPoint
    public let confidence: Float
    public init(position: CGPoint, confidence: Float) {
        self.position = position
        self.confidence = confidence
    }
}

public struct Skeleton: Equatable {
    public let joints: [BodyJoint: JointPoint]
    public init(joints: [BodyJoint: JointPoint]) { self.joints = joints }

    public func point(_ j: BodyJoint) -> JointPoint? { joints[j] }

    /// Horizontal center of the subject: mid-shoulders, else mid-hips, else nil.
    public func centerX() -> CGFloat? {
        if let l = joints[.leftShoulder], let r = joints[.rightShoulder] {
            return (l.position.x + r.position.x) / 2
        }
        if let l = joints[.leftHip], let r = joints[.rightHip] {
            return (l.position.x + r.position.x) / 2
        }
        return nil
    }

    /// Top-most visible head/torso y (smaller = higher on screen): nose, else neck, else nil.
    public func topOfHeadY() -> CGFloat? {
        joints[.nose]?.position.y ?? joints[.neck]?.position.y
    }
}

public struct Hint: Equatable {
    public enum Kind: Equatable { case composition, pose }
    public enum Severity: Equatable { case info, warn }
    public let kind: Kind
    public let severity: Severity
    public let text: String
    /// Stable identifier for testing / dedup, e.g. "tilt.level".
    public let code: String
    public init(kind: Kind, severity: Severity, text: String, code: String) {
        self.kind = kind; self.severity = severity; self.text = text; self.code = code
    }
}
