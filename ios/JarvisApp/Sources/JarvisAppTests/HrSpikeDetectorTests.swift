import XCTest
@testable import Jarvis

final class HrSpikeDetectorTests: XCTestCase {

    private func sample(_ bpm: Double, secondsAgo: TimeInterval, from now: Date) -> HrSpikeDetector.Sample {
        .init(bpm: bpm, at: now.addingTimeInterval(-secondsAgo))
    }

    func testQuietStreamReturnsFalse() {
        let now = Date()
        let stream = (0..<120).map { i in
            sample(70, secondsAgo: TimeInterval(120 - i), from: now)
        }
        XCTAssertFalse(HrSpikeDetector.detect(samples: stream, baseline: 70, now: now))
    }

    func testShortSpikeBelowOneMinuteReturnsFalse() {
        let now = Date()
        var stream: [HrSpikeDetector.Sample] = []
        for i in 0..<90 { stream.append(sample(70, secondsAgo: TimeInterval(120 - i), from: now)) }
        for i in 90..<120 { stream.append(sample(110, secondsAgo: TimeInterval(120 - i), from: now)) }
        XCTAssertFalse(HrSpikeDetector.detect(samples: stream, baseline: 70, now: now))
    }

    func testSustainedSpikeOverThresholdReturnsTrue() {
        let now = Date()
        var stream: [HrSpikeDetector.Sample] = []
        for i in 0..<60 { stream.append(sample(70, secondsAgo: TimeInterval(120 - i), from: now)) }
        for i in 60..<120 { stream.append(sample(110, secondsAgo: TimeInterval(120 - i), from: now)) }
        XCTAssertTrue(HrSpikeDetector.detect(samples: stream, baseline: 70, now: now))
    }

    func testJustBelowThresholdReturnsFalse() {
        let now = Date()
        var stream: [HrSpikeDetector.Sample] = []
        for i in 0..<60 { stream.append(sample(70, secondsAgo: TimeInterval(120 - i), from: now)) }
        for i in 60..<120 { stream.append(sample(99, secondsAgo: TimeInterval(120 - i), from: now)) }
        XCTAssertFalse(HrSpikeDetector.detect(samples: stream, baseline: 70, now: now))
    }
}
