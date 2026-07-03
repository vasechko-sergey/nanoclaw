// Sources/JarvisApp/PosingCoach/HintStabilizer.swift

/// Debounces hint appearance/disappearance across frames to stop UI flicker.
public final class HintStabilizer {
    private let appearFrames: Int
    private let disappearFrames: Int
    private var presentStreak: [String: Int] = [:]   // code → consecutive present frames
    private var absentStreak: [String: Int] = [:]    // code → consecutive absent frames
    private var shown: [String: Hint] = [:]          // currently surfaced

    public init(appearFrames: Int = 4, disappearFrames: Int = 6) {
        self.appearFrames = appearFrames
        self.disappearFrames = disappearFrames
    }

    /// Feed this frame's raw hints; get the stabilized set to render.
    public func step(_ raw: [Hint]) -> [Hint] {
        let codes = Set(raw.map(\.code))
        let byCode = Dictionary(raw.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })

        for code in Array(presentStreak.keys) where !codes.contains(code) {
            presentStreak[code] = 0
        }
        for h in raw {
            presentStreak[h.code, default: 0] += 1
            absentStreak[h.code] = 0
            if presentStreak[h.code]! >= appearFrames { shown[h.code] = h }
        }
        for code in Array(shown.keys) where !codes.contains(code) {
            absentStreak[code, default: 0] += 1
            presentStreak[code] = 0
            if absentStreak[code]! >= disappearFrames {
                shown[code] = nil
                presentStreak[code] = nil
                absentStreak[code] = nil
            }
        }
        // Keep shown hints fresh with their latest text when still present.
        for (code, h) in byCode where shown[code] != nil { shown[code] = h }
        // Stable order: warnings before infos, then by code.
        return shown.values.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity == .warn }
            return lhs.code < rhs.code
        }
    }
}
