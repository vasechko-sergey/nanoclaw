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
    static let tiltThresholdDegrees = 3.0

    public static func hints(skeleton: Skeleton, frame: FrameInfo) -> [Hint] {
        var out: [Hint] = []
        if let h = tiltHint(frame) { out.append(h) }
        if let h = headroomHint(skeleton) { out.append(h) }
        out.append(contentsOf: cropHints(skeleton))
        if let h = thirdsHint(skeleton) { out.append(h) }
        return out
    }

    static func tiltHint(_ frame: FrameInfo) -> Hint? {
        guard abs(frame.tiltDegrees) > tiltThresholdDegrees else { return nil }
        return Hint(kind: .composition, severity: .warn,
                    text: "Выровняй горизонт", code: "tilt.level")
    }

    static let headroomTight = 0.05
    static let headroomLoose = 0.22

    static func headroomHint(_ s: Skeleton) -> Hint? {
        guard let top = s.topOfHeadY() else { return nil }
        if top < headroomTight {
            return Hint(kind: .composition, severity: .warn,
                        text: "Мало места над головой — приподними камеру",
                        code: "headroom.tight")
        }
        if top > headroomLoose {
            return Hint(kind: .composition, severity: .info,
                        text: "Много пустоты сверху — опусти камеру",
                        code: "headroom.loose")
        }
        return nil
    }

    static func cropHints(_ s: Skeleton) -> [Hint] {
        var out: [Hint] = []
        let kneesVisible = s.point(.leftKnee) != nil || s.point(.rightKnee) != nil
        let anklesVisible = s.point(.leftAnkle) != nil || s.point(.rightAnkle) != nil
        if kneesVisible && !anklesVisible {
            out.append(Hint(kind: .composition, severity: .warn,
                            text: "Не режь по щиколотке — влезь целиком или кадрируй выше колена",
                            code: "crop.ankle"))
        }
        return out
    }

    static let centerBand = 0.06      // how close to 0.5 counts as "dead center"
    static let thirdClearance = 0.10  // must be this far from a third line to bother nudging

    static func thirdsHint(_ s: Skeleton) -> Hint? {
        guard let cx = s.centerX() else { return nil }
        let nearestThird = min(abs(cx - 1.0/3), abs(cx - 2.0/3))
        let toCenter = abs(cx - 0.5)
        if toCenter < centerBand && nearestThird > thirdClearance {
            return Hint(kind: .composition, severity: .info,
                        text: "Поставь модель на линию трети",
                        code: "thirds.center")
        }
        return nil
    }
}
