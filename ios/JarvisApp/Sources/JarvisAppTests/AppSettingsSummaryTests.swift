import XCTest
@testable import Jarvis

final class AppSettingsSummaryTests: XCTestCase {
    func testSummaryNotificationsDefaultTrue() {
        // Clean any previously stored value so we see the real default.
        UserDefaults.standard.removeObject(forKey: "summaryNotificationsEnabled")
        let s = AppSettings()
        XCTAssertTrue(s.summaryNotificationsEnabled, "summaryNotificationsEnabled should default to true")
    }

    func testSummaryNotificationsPersists() {
        let s = AppSettings()
        s.summaryNotificationsEnabled = false
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: "summaryNotificationsEnabled") as? Bool,
            false,
            "summaryNotificationsEnabled=false should be written to UserDefaults"
        )
        // Restore
        UserDefaults.standard.removeObject(forKey: "summaryNotificationsEnabled")
    }
}
