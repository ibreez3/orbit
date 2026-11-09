import XCTest
@testable import AgentKit

final class AgentMCPTests: XCTestCase {
    func testToolsListContainsOnlyGenericReadTools() {
        let core = MCPBridgeCore(client: FakeGatewayClient())
        let response = core.handle(MCPRequest(
            jsonrpc: "2.0",
            id: .string("1"),
            method: "tools/list",
            params: nil
        ))
        let names = toolNames(response)
        XCTAssertTrue(names.contains(AgentToolName.listServers))
        XCTAssertTrue(names.contains(AgentToolName.exec))
        XCTAssertTrue(names.contains(AgentToolName.shellOpen))
        XCTAssertTrue(names.contains(AgentToolName.shellExec))
        XCTAssertTrue(names.contains(AgentToolName.shellClose))
        XCTAssertFalse(names.contains("orbit_list_containers"))
        XCTAssertFalse(names.contains("orbit_docker_logs"))
    }

    func testToolsCallWithoutAdmissionReturnsPending() {
        let client = FakeGatewayClient(admission: .pending(requestId: "req-1"))
        let core = MCPBridgeCore(client: client)
        let response = core.handle(MCPRequest(
            jsonrpc: "2.0",
            id: .string("2"),
            method: "tools/call",
            params: .object([
                "name": .string(AgentToolName.listServers),
                "arguments": .object([:])
            ])
        ))
        XCTAssertTrue(textContent(response).contains("pending_approval"))
    }

    func testToolsCallAfterApprovalReturnsServerList() {
        let client = FakeGatewayClient(admission: .approved(.init(sessionId: "s", token: "t")))
        let core = MCPBridgeCore(client: client)
        let response = core.handle(MCPRequest(
            jsonrpc: "2.0",
            id: .string("3"),
            method: "tools/call",
            params: .object([
                "name": .string(AgentToolName.listServers),
                "arguments": .object([:])
            ])
        ))
        XCTAssertTrue(textContent(response).contains("servers"))
    }

    private func toolNames(_ response: MCPResponse?) -> [String] {
        guard case .object(let result)? = response?.result,
              case .array(let tools)? = result["tools"] else {
            return []
        }
        return tools.compactMap { tool in
            guard case .object(let object) = tool else { return nil }
            return object["name"]?.stringValue
        }
    }

    private func textContent(_ response: MCPResponse?) -> String {
        guard case .object(let result)? = response?.result,
              case .array(let content)? = result["content"],
              case .object(let first) = content.first,
              case .string(let text)? = first["text"] else {
            return ""
        }
        return text
    }
}

final class FakeGatewayClient: AgentGatewayCalling {
    var admission: AgentAdmissionResult
    private(set) var callCount = 0
    private(set) var lastTool: String?
    private(set) var lastArgs: AgentJSONValue?

    init(admission: AgentAdmissionResult = .approved(.init(sessionId: "s", token: "t"))) {
        self.admission = admission
    }

    func hello(_ hello: AgentHello) throws -> AgentAdmissionResult {
        admission
    }

    func approvalStatus(requestId: String) throws -> AgentApprovalStatus {
        switch admission {
        case .approved(let session):
            return AgentApprovalStatus(requestId: requestId, status: .approved, session: session)
        case .pending:
            return AgentApprovalStatus(requestId: requestId, status: .pending)
        case .denied(let error):
            return AgentApprovalStatus(requestId: requestId, status: .denied, error: error)
        }
    }

    func call(tool: String, args: AgentJSONValue, session: AgentSessionCredential) throws -> AgentJSONValue {
        callCount += 1
        lastTool = tool
        lastArgs = args
        switch tool {
        case AgentToolName.jobStatus:
            return .object(["status": .string("running")])
        case AgentToolName.jobOutput:
            return .object(["chunk": .string(""), "nextCursor": .number(0), "eof": .bool(false)])
        case AgentToolName.jobCancel:
            return .object(["status": .string("cancelled")])
        default:
            return .object(["servers": .array([])])
        }
    }

    func revoke(_ session: AgentSessionCredential) throws {}
}
