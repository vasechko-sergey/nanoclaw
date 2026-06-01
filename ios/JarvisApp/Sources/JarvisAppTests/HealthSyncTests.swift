import XCTest
@testable import Jarvis

final class HealthSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HealthSyncTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_kickIfStale_noPriorUpload_callsPushRecent() {
        var pushed = false
        let calls = HealthSync.kickIfStaleForTesting(
            now: Date(timeIntervalSince1970: 1_800_000_000),
            calendar: Calendar(identifier: .gregorian),
            defaults: defaults,
            push: { done in pushed = true; done() }
        )
        XCTAssertTrue(pushed)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(defaults.object(forKey: "lastHealthUploadAt"))
    }

    func test_kickIfStale_uploadedYesterday_callsPushRecent() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        defaults.set(yesterday, forKey: "lastHealthUploadAt")

        var pushed = false
        let calls = HealthSync.kickIfStaleForTesting(
            now: now,
            calendar: cal,
            defaults: defaults,
            push: { done in pushed = true; done() }
        )
        XCTAssertTrue(pushed)
        XCTAssertEqual(calls, 1)
    }

    func test_kickIfStale_uploadedToday_noOps() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let earlierToday = cal.date(byAdding: .hour, value: -3, to: now)!
        defaults.set(earlierToday, forKey: "lastHealthUploadAt")

        var pushed = false
        let calls = HealthSync.kickIfStaleForTesting(
            now: now,
            calendar: cal,
            defaults: defaults,
            push: { done in pushed = true; done() }
        )
        XCTAssertFalse(pushed)
        XCTAssertEqual(calls, 0)
    }

    func test_kickIfStale_futureDate_noOps() {
        // Clock-skew safety: a future lastUpload is treated as "already uploaded today".
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        defaults.set(tomorrow, forKey: "lastHealthUploadAt")

        var pushed = false
        _ = HealthSync.kickIfStaleForTesting(
            now: now,
            calendar: cal,
            defaults: defaults,
            push: { done in pushed = true; done() }
        )
        XCTAssertFalse(pushed)
    }
}
