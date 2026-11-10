import XCTest
@testable import Orbit
@testable import AgentKit

final class AgentAuditStoreTests: XCTestCase {
    func testAuditEventEncodesWithoutSecretsAndAppendsJSONLine() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("audit.log")
        let store = AgentAuditStore(logURL: logURL)
        store.record(AgentAuditEvent(
            id: "e1",
            timestamp: Date(timeIntervalSince1970: 0),
            type: "tool.call",
            sessionId: "s",
            agent: "Claude Code",
            serverId: "srv",
            tool: "orbit_exec",
            command: "docker ps",
            mode: "read",
            exitCode: 0,
            durationMs: 12,
            stdoutBytes: 3,
            stderrBytes: 0,
            result: "ok"
        ))
        store.flush()

        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"tool\":\"orbit_exec\""))
        XCTAssertFalse(text.lowercased().contains("password"))
        XCTAssertFalse(text.lowercased().contains("token"))
    }
}
