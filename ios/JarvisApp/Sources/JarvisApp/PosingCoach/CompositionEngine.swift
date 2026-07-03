// Sources/JarvisApp/PosingCoach/CompositionEngine.swift
import CoreGraphics

/// Frame-level context for composition rules.
public struct FrameInfo: Equatable {
    public let size: CGSize
    /// Device roll relative to horizontal, degrees. + = tilted, sign-agnostic here.
    public let tiltDegrees: Double
    public init(size: CGSize, tiltDegrees: Double) {
        self.size = size; self.tiltDegrees = tiltDegrees
    }
}

/// Pure: skeleton (screen space) + frame → composition hints. No I/O, fully testable.
public enum CompositionEngine {
    static let tiltThresholdDegrees = 4.0

    public static func hints(skeleton: Skeleton, frame: FrameInfo) -> [Hint] {
        var out: [Hint] = []
        if let h = tiltHint(frame) { out.append(h) }
        return out
    }

    static func tiltHint(_ frame: FrameInfo) -> Hint? {
        guard abs(frame.tiltDegrees) > tiltThresholdDegrees else { return nil }
        return Hint(kind: .composition, severity: .warn,
                    text: "Выровняй горизонт", code: "tilt.level")
    }
}
