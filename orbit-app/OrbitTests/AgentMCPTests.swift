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

    func testExpiredSessionTriggersReadmissionOnNextCall() {
        let client = ExpiringGatewayClient()
        let core = MCPBridgeCore(client: client)

        let first = core.handle(MCPRequest(
            jsonrpc: "2.0",
            id: .string("1"),
            method: "tools/call",
            params: .object([
                "name": .string(AgentToolName.listServers),
                "arguments": .object([:])
            ])
        ))
        XCTAssertTrue(textContent(first).contains("pending_approval"))

        let second = core.handle(MCPRequest(
            jsonrpc: "2.0",
            id: .string("2"),
            method: "tools/call",
            params: .object([
                "name": .string(AgentToolName.listServers),
                "arguments": .object([:])
            ])
        ))
        XCTAssertTrue(textContent(second).contains("servers"))
        XCTAssertEqual(client.helloCount, 2)
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
        case AgentToolName.shellOpen:
            return .object(["shellId": .string("shell-1")])
        case AgentToolName.shellExec:
            return .object(["output": .string("hi"), "exitCode": .number(0)])
        case AgentToolName.shellClose:
            return .object(["status": .string("closed")])
        default:
            return .object(["servers": .array([])])
        }
    }

    func revoke(_ session: AgentSessionCredential) throws {}
}

final class ExpiringGatewayClient: AgentGatewayCalling {
    private(set) var helloCount = 0
    private(set) var callCount = 0

    func hello(_ hello: AgentHello) throws -> AgentAdmissionResult {
        helloCount += 1
        return .approved(AgentSessionCredential(
            sessionId: "session-\(helloCount)",
            token: "token-\(helloCount)"
        ))
    }

    func approvalStatus(requestId: String) throws -> AgentApprovalStatus {
        AgentApprovalStatus(
            requestId: requestId,
            status: .approved,
            session: AgentSessionCredential(sessionId: "session", token: "token")
        )
    }

    func call(
        tool: String,
        args: AgentJSONValue,
        session: AgentSessionCredential
    ) throws -> AgentJSONValue {
        callCount += 1
        if callCount == 1 {
            throw AgentSocketClientError.remote(AgentErrorBody(
                code: .sessionExpired,
                message: "The agent session expired"
            ))
        }
        return .object(["servers": .array([])])
    }

    func revoke(_ session: AgentSessionCredential) throws {}
}
