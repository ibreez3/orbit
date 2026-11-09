import XCTest
@testable import Orbit
@testable import AgentKit

final class AgentGatewayTests: XCTestCase {
    func testCallWithoutTokenIsUnauthorized() async {
        let gateway = makeGateway(approver: FakeApprover(result: true))
        let response = await gateway.handle(
            AgentRequest(
                id: "1",
                op: .call,
                tool: AgentToolName.listServers,
                args: nil
            )
        )
        XCTAssertEqual(response.error?.code, .unauthorized)
    }

    func testHelloApprovalIssuesTokenAndCallSucceeds() async throws {
        let approver = FakeApprover(result: true)
        let gateway = makeGateway(approver: approver)
        let hello = await gateway.handle(
            AgentRequest(
                id: "1",
                op: .hello,
                args: .object(["clientName": .string("Claude Code")])
            )
        )
        guard case .object(let object)? = hello.result,
              let sessionId = object["sessionId"]?.stringValue,
              let token = object["token"]?.stringValue else {
            return XCTFail("expected approved session, got \(String(describing: hello))")
        }
        let response = await gateway.handle(
            AgentRequest(
                id: "2",
                op: .call,
                sessionId: sessionId,
                token: token,
                tool: AgentToolName.listServers,
                args: nil
            )
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(approver.admissionCount, 1)
    }

    func testSlowApprovalReturnsPendingWithoutExecuting() async {
        let approver = FakeApprover(result: true, delayMs: 100)
        let gateway = makeGateway(approver: approver, approvalWait: 0.01)
        let response = await gateway.handle(
            AgentRequest(
                id: "1",
                op: .hello,
                args: .object(["clientName": .string("Codex")])
            )
        )
        guard case .object(let object)? = response.result else {
            return XCTFail("expected pending response")
        }
        XCTAssertEqual(object["status"]?.stringValue, "pending_approval")
        XCTAssertNotNil(object["requestId"]?.stringValue)
    }

    private func makeGateway(
        approver: AgentApprovalPresenting,
        approvalWait: TimeInterval = 5,
        servers: [AgentServerSummary] = []
    ) -> AgentGateway {
        AgentGateway(
            execService: FakeExecService(servers: servers),
            approval: approver,
            sessions: AgentSessionStore(),
            audit: FakeAudit(),
            approvalWait: approvalWait,
            socketPath: NSTemporaryDirectory() + "test-\(UUID().uuidString).sock"
        )
    }
}

final class FakeApprover: AgentApprovalPresenting {
    let result: Bool
    let delayMs: UInt64
    private(set) var admissionCount = 0
    private(set) var writeCount = 0

    init(result: Bool, delayMs: UInt64 = 0) {
        self.result = result
        self.delayMs = delayMs
    }

    func requestAdmission(_ request: AgentAdmissionRequest) async -> Bool {
        admissionCount += 1
        if delayMs > 0 {
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }
        return result
    }

    func requestWrite(_ request: AgentWriteRequest) async -> Bool {
        writeCount += 1
        return result
    }
}

final class FakeExecService: AgentCommandExecuting {
    let servers: [AgentServerSummary]

    init(servers: [AgentServerSummary] = []) {
        self.servers = servers
    }

    func listServers() -> [AgentServerSummary] {
        servers
    }

    func exec(_ request: AgentExecRequest) async throws -> AgentExecResult {
        AgentExecResult(
            status: .completed,
            serverId: request.serverQuery,
            stdout: "ok",
            exitCode: 0,
            durationMs: 1,
            mode: request.mode
        )
    }

    func jobStatus(jobId: String) async throws -> AgentJobStatus {
        AgentJobStatus(jobId: jobId, status: .completed, exitCode: 0, durationMs: 1, truncated: false)
    }

    func jobOutput(jobId: String, cursor: Int?) async throws -> AgentJobOutput {
        AgentJobOutput(jobId: jobId, chunk: "", nextCursor: cursor ?? 0, eof: true, truncated: false)
    }

    func jobCancel(jobId: String) async throws {}

    func cancelJobs(serverId: String) {}
}

final class FakeAudit: AgentAuditRecording {
    private(set) var events: [AgentAuditEvent] = []

    func record(_ event: AgentAuditEvent) {
        events.append(event)
    }
}

extension AgentServerSummary {
    static func fixture(
        id: String,
        name: String = "server",
        host: String = "10.0.0.1"
    ) -> AgentServerSummary {
        AgentServerSummary(
            id: id,
            name: name,
            host: host,
            port: 22,
            username: "user",
            folder: nil,
            tags: [],
            aiEnabled: true
        )
    }
}
