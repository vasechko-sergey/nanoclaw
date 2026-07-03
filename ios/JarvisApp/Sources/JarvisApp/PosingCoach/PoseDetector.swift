// Sources/JarvisApp/PosingCoach/PoseDetector.swift
import Vision
import CoreGraphics
import CoreVideo

public enum PoseDetector {
    /// Map Vision joint names to our BodyJoint. Returns nil for joints we ignore.
    public static func map(_ name: VNHumanBodyPoseObservation.JointName) -> BodyJoint? {
        switch name {
        case .nose: return .nose
        case .neck: return .neck
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        case .root: return .root
        default: return nil
        }
    }

    /// Vision normalized (origin bottom-left, y up) → screen normalized (top-left, y down).
    public static func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }

    static let minConfidence: Float = 0.3

    /// Run body-pose detection on a camera frame. Nil if no body found.
    public static func detect(pixelBuffer: CVPixelBuffer,
                              orientation: CGImagePropertyOrientation = .up) throws -> Skeleton? {
        let req = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([req])
        guard let obs = req.results?.first else { return nil }
        var joints: [BodyJoint: JointPoint] = [:]
        for (name, point) in (try? obs.recognizedPoints(.all)) ?? [:] {
            guard point.confidence >= minConfidence, let j = map(name) else { continue }
            joints[j] = JointPoint(position: toScreen(point.location), confidence: point.confidence)
        }
        return joints.isEmpty ? nil : Skeleton(joints: joints)
    }
}
