import XCTest
@testable import AgentKit

final class AgentProtocolTests: XCTestCase {
    func testAgentRequestRoundTripsThroughJSON() throws {
        let request = AgentRequest(
            id: "1",
            op: .call,
            sessionId: "s",
            token: "t",
            tool: AgentToolName.listServers,
            args: .object(["server": .string("10.1.101.132")])
        )
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(AgentRequest.self, from: data), request)
    }

    func testJSONValueSupportsNestedObjects() throws {
        let value = AgentJSONValue.object([
            "a": .array([.number(1), .bool(true), .null])
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(AgentJSONValue.self, from: data), value)
    }

    func testAgentPathsUseApplicationSupport() {
        XCTAssertTrue(AgentPaths.socketPath.hasSuffix("/agent/agent.sock"))
        XCTAssertTrue(AgentPaths.socketPath.contains("Library/Application Support/Orbit"))
    }

    func testAgentNumericClampsAgentSuppliedValues() {
        XCTAssertEqual(
            AgentNumeric.uint32(1e12, default: 30_000, range: 1...300_000),
            300_000
        )
        XCTAssertEqual(
            AgentNumeric.uint32(-5, default: 30_000, range: 1...300_000),
            1
        )
        XCTAssertEqual(
            AgentNumeric.uint32(.nan, default: 30_000, range: 1...300_000),
            30_000
        )
        XCTAssertEqual(AgentNumeric.int32(1e12, default: 0), Int32.max)
        XCTAssertEqual(AgentNumeric.int32(.infinity, default: 7), 7)
        XCTAssertEqual(AgentNumeric.int(-5, default: 0, range: 0...100), 0)
        XCTAssertEqual(AgentNumeric.int(1.9, default: 0, range: 0...100), 1)
    }

    func testAgentSupportDirectoryHonorsEnvironmentOverride() {
        let key = "ORBIT_AGENT_SUPPORT_DIR"
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, "/tmp/orbit-agent-paths-test", 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        XCTAssertEqual(AgentPaths.supportDirectory.path, "/tmp/orbit-agent-paths-test")
        XCTAssertEqual(AgentPaths.socketPath, "/tmp/orbit-agent-paths-test/agent.sock")
    }
}
