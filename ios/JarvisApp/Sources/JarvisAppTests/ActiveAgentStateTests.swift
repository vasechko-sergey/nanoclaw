import XCTest
@testable import Jarvis

@MainActor
final class ActiveAgentStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "ActiveAgentState.active")
    }

    func test_defaultsToJarvis_whenNoPersistedValue() {
        let state = ActiveAgentState()
        XCTAssertEqual(state.active, .jarvis)
    }

    func test_persistsSelection_acrossInstances() {
        let a = ActiveAgentState()
        a.active = .payne
        let b = ActiveAgentState()
        XCTAssertEqual(b.active, .payne)
    }

    func test_initialOverride_respected() {
        let state = ActiveAgentState(initial: .greg)
        XCTAssertEqual(state.active, .greg)
    }

    func test_agentIdentity_rawValuesMatchAgentSlugs() {
        // These must match the host's agent_group folder slugs.
        XCTAssertEqual(AgentIdentity.jarvis.rawValue, "jarvis")
        XCTAssertEqual(AgentIdentity.payne.rawValue, "payne")
        XCTAssertEqual(AgentIdentity.greg.rawValue, "greg")
    }
}
