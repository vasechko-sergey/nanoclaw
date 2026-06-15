import XCTest
import SwiftUI
@testable import Jarvis

final class AgentSatelliteSelectionTests: XCTestCase {
    func testOrbitExcludesActiveAndCoversOthers() {
        let ids = OrbHubPane.satelliteAgents(active: .jarvis).map { $0.rawValue }
        XCTAssertFalse(ids.contains("jarvis"))
        XCTAssertEqual(Set(ids), Set(["payne", "greg", "scrooge", "gordon"]))
    }
    func testActiveAgentDrivesCoreAccent() {
        XCTAssertEqual(OrbHubPane.coreAccent(active: .payne), AgentIdentity.payne.accentColor)
    }
}
