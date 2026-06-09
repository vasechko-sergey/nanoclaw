import XCTest
@testable import Jarvis

@MainActor
final class LastSeenStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LastSeenStoreTests-\(UUID().uuidString)")
    }

    func testDefaultLastSeenIsDistantPast() {
        let store = LastSeenStore(defaults: defaults)
        XCTAssertEqual(store.lastSeen(for: .payne), .distantPast)
    }

    func testMarkSeenPersists() {
        let store = LastSeenStore(defaults: defaults)
        let t = Date()
        store.markSeen(.payne, at: t)
        XCTAssertEqual(store.lastSeen(for: .payne), t)

        let reloaded = LastSeenStore(defaults: defaults)
        XCTAssertEqual(reloaded.lastSeen(for: .payne), t)
    }

    func testPerAgentIsolation() {
        let store = LastSeenStore(defaults: defaults)
        let t = Date()
        store.markSeen(.payne, at: t)
        XCTAssertEqual(store.lastSeen(for: .jarvis), .distantPast)
    }
}
