import XCTest
@testable import AgentKit

final class AgentSessionStoreTests: XCTestCase {
    func testTokenIsBoundToSessionAndPingDoesNotRefreshIdle() {
        var now = Date(timeIntervalSince1970: 0)
        let store = AgentSessionStore(clock: { now }, idleTimeout: 30, maxLifetime: 100)
        let session = store.createSession(agentName: "Claude Code")
        now += 31
        XCTAssertEqual(store.validate(session), .expired)
    }

    func testActiveJobKeepsSessionAliveAndWriteGrantIsPerServer() {
        var now = Date(timeIntervalSince1970: 0)
        let store = AgentSessionStore(clock: { now }, idleTimeout: 30, maxLifetime: 100)
        let session = store.createSession(agentName: "Codex")
        store.markJobActive(sessionId: session.sessionId, jobId: "job-1")
        now += 31
        XCTAssertEqual(store.validate(session), .valid)
        store.grantWrite(sessionId: session.sessionId, serverId: "a")
        XCTAssertTrue(store.hasWriteGrant(sessionId: session.sessionId, serverId: "a"))
        XCTAssertFalse(store.hasWriteGrant(sessionId: session.sessionId, serverId: "b"))
        store.markJobFinished(sessionId: session.sessionId, jobId: "job-1")
        now += 31
        XCTAssertEqual(store.validate(session), .expired)
    }

    func testRevokeAllInvalidatesTokens() {
        let store = AgentSessionStore()
        let session = store.createSession(agentName: "Claude Code")
        store.revokeAll()
        XCTAssertEqual(store.validate(session), .unauthorized)
        XCTAssertFalse(store.hasActiveSessions)
    }
}
