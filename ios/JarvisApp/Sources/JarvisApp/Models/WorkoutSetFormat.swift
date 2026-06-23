import Foundation

/// Pure formatting/derivation helpers for set logging, extracted from the view
/// layer so they're unit-testable.
enum WorkoutSetFormat {
    /// Middle of a target-reps range. "8-10" → 9, "12" → 12, "" → 8.
    static func midReps(targetReps: String) -> Int {
        let parts = targetReps.split(separator: "-").compactMap { Int($0) }
        if parts.count == 2 { return (parts[0] + parts[1]) / 2 }
        if parts.count == 1 { return parts[0] }
        return 8
    }

    /// Whole numbers drop the decimal. 60.0 → "60", 62.5 → "62.5".
    static func weight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(w)) : String(format: "%.1f", w)
    }

    /// Seconds → "M:SS". 300 → "5:00", 90 → "1:30".
    static func duration(_ sec: Int) -> String {
        String(format: "%d:%02d", sec / 60, sec % 60)
    }
}
