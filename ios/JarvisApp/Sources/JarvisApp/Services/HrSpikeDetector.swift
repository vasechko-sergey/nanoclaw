import Foundation

/// Pure heart-rate spike detector. No HealthKit or AVFoundation dependency.
/// Used by HealthManager.HRObserver to decide whether to fire a
/// `health_hr_spike` proactive trigger.
///
/// Definition: a spike is when the maximum bpm in the trailing window stays
/// at or above `baseline + 30` for at least 60 continuous seconds. The
/// detector intentionally returns Bool only — no values cross the boundary.
enum HrSpikeDetector {

    struct Sample: Equatable {
        let bpm: Double
        let at: Date
    }

    /// Threshold above resting baseline that counts as a spike.
    private static let spikeOffset: Double = 30

    /// Minimum duration (seconds) the spike must be sustained.
    /// Slight tolerance below 60s absorbs HK sampling granularity — a stream
    /// of 60 one-per-second elevated samples covers a 59s span between the
    /// first and last point but represents ~60s of elevation.
    private static let minDuration: TimeInterval = 59

    /// Returns true if a spike is detected in the trailing samples.
    /// - Parameters:
    ///   - samples: HR samples in any order (the function sorts).
    ///   - baseline: resting baseline bpm (e.g. HKQuantityType .restingHeartRate or a fallback of 70).
    ///   - now: current wall clock (injectable for tests).
    static func detect(samples: [Sample], baseline: Double, now: Date) -> Bool {
        guard !samples.isEmpty else { return false }
        let threshold = baseline + spikeOffset
        let sorted = samples.sorted { $0.at < $1.at }

        var spikeStart: Date? = nil
        for s in sorted {
            if s.bpm >= threshold {
                if spikeStart == nil { spikeStart = s.at }
                if let start = spikeStart, s.at.timeIntervalSince(start) >= minDuration {
                    return true
                }
            } else {
                spikeStart = nil
            }
        }
        return false
    }
}
