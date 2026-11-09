import XCTest
@testable import Orbit

final class AgentLifecycleTests: XCTestCase {
    func testWindowCloseKeepsOrbitAliveOnlyWithActiveAgentSessions() {
        XCTAssertFalse(shouldTerminateAfterLastWindowClosed(activeAgentSessions: 1))
        XCTAssertTrue(shouldTerminateAfterLastWindowClosed(activeAgentSessions: 0))
    }
}
