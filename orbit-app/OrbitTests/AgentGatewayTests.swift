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

    func testFirstWriteRequiresApprovalThenReusesGrant() async throws {
        let approver = FakeApprover(result: true)
        let gateway = makeGateway(
            approver: approver,
            servers: [.fixture(id: "srv")]
        )
        let session = try await approveSession(gateway)

        let first = await gateway.handle(callRequest(
            id: "1",
            session: session,
            args: [
                "server": .string("srv"),
                "command": .string("rm x"),
                "mode": .string("write")
            ]
        ))
        XCTAssertTrue(first.ok)

        let second = await gateway.handle(callRequest(
            id: "2",
            session: session,
            args: [
                "server": .string("srv"),
                "command": .string("rm y"),
                "mode": .string("write")
            ]
        ))
        XCTAssertTrue(second.ok)
        XCTAssertEqual(approver.writeCount, 1)
    }

    func testDisablingServerRevokesWriteGrantAndRejectsCalls() async throws {
        let approver = FakeApprover(result: true)
        let gateway = makeGateway(
            approver: approver,
            servers: [.fixture(id: "srv")]
        )
        let session = try await approveSession(gateway)

        let write = await gateway.handle(callRequest(
            id: "1",
            session: session,
            args: [
                "server": .string("srv"),
                "command": .string("rm x"),
                "mode": .string("write")
            ]
        ))
        XCTAssertTrue(write.ok)

        gateway.applyServerExposureChange(serverId: "srv", enabled: false)
        XCTAssertFalse(gateway.sessions.hasWriteGrant(sessionId: session.sessionId, serverId: "srv"))

        let read = await gateway.handle(callRequest(
            id: "2",
            session: session,
            args: [
                "server": .string("srv"),
                "command": .string("ls"),
                "mode": .string("read")
            ]
        ))
        XCTAssertEqual(read.error?.code, .serverNotExposed)
    }

    func testShellToolsRequireWriteApprovalThenRouteToManager() async throws {
        let approver = FakeApprover(result: true)
        let shells = FakeShellManager()
        let gateway = makeGateway(
            approver: approver,
            servers: [.fixture(id: "srv")],
            shellManager: shells
        )
        let session = try await approveSession(gateway)

        let open = await gateway.handle(callRequest(
            id: "1",
            session: session,
            tool: AgentToolName.shellOpen,
            args: ["server": .string("srv")]
        ))
        XCTAssertTrue(open.ok)
        XCTAssertEqual(approver.writeCount, 1)
        guard case .object(let object)? = open.result,
              let shellId = object["shellId"]?.stringValue else {
            return XCTFail("expected shellId, got \(String(describing: open))")
        }

        let exec = await gateway.handle(callRequest(
            id: "2",
            session: session,
            tool: AgentToolName.shellExec,
            args: [
                "shellId": .string(shellId),
                "command": .string("echo hi")
            ]
        ))
        XCTAssertTrue(exec.ok)
        XCTAssertEqual(shells.executed.last?.command, "echo hi")

        let close = await gateway.handle(callRequest(
            id: "3",
            session: session,
            tool: AgentToolName.shellClose,
            args: ["shellId": .string(shellId)]
        ))
        XCTAssertTrue(close.ok)
        XCTAssertEqual(shells.closed, [shellId])
    }

    func testDisablingServerClosesItsShells() async throws {
        let shells = FakeShellManager()
        let gateway = makeGateway(
            approver: FakeApprover(result: true),
            servers: [.fixture(id: "srv")],
            shellManager: shells
        )
        let session = try await approveSession(gateway)
        let open = await gateway.handle(callRequest(
            id: "1",
            session: session,
            tool: AgentToolName.shellOpen,
            args: ["server": .string("srv")]
        ))
        guard case .object(let object)? = open.result,
              let shellId = object["shellId"]?.stringValue else {
            return XCTFail("expected shellId, got \(String(describing: open))")
        }

        gateway.applyServerExposureChange(serverId: "srv", enabled: false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(shells.closeAllServerIds, ["srv"])

        let exec = await gateway.handle(callRequest(
            id: "2",
            session: session,
            tool: AgentToolName.shellExec,
            args: [
                "shellId": .string(shellId),
                "command": .string("echo hi")
            ]
        ))
        XCTAssertNotNil(exec.error)
    }

    func testExpiredSessionClosesItsShells() async throws {
        let clock = MutableClock()
        let sessions = AgentSessionStore(
            clock: { clock.now },
            idleTimeout: 1800,
            maxLifetime: 8 * 3600
        )
        let shells = FakeShellManager()
        let gateway = makeGateway(
            approver: FakeApprover(result: true),
            servers: [.fixture(id: "srv")],
            shellManager: shells,
            sessions: sessions
        )
        let session = try await approveSession(gateway)
        let open = await gateway.handle(callRequest(
            id: "1",
            session: session,
            tool: AgentToolName.shellOpen,
            args: ["server": .string("srv")]
        ))
        XCTAssertTrue(open.ok)

        clock.now = clock.now.addingTimeInterval(8 * 3600 + 1)
        let response = await gateway.handle(AgentRequest(
            id: "2",
            op: .call,
            sessionId: session.sessionId,
            token: session.token,
            tool: AgentToolName.listServers,
            args: nil
        ))
        XCTAssertEqual(response.error?.code, .sessionExpired)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(shells.closeAllSessionIds, [session.sessionId])
    }

    func testShellExecRequiresWriteGrant() async throws {
        let shells = FakeShellManager()
        let gateway = makeGateway(
            approver: FakeApprover(result: true),
            servers: [.fixture(id: "srv")],
            shellManager: shells
        )
        let session = try await approveSession(gateway)
        let open = await gateway.handle(callRequest(
            id: "1",
            session: session,
            tool: AgentToolName.shellOpen,
            args: ["server": .string("srv")]
        ))
        guard case .object(let object)? = open.result,
              let shellId = object["shellId"]?.stringValue else {
            return XCTFail("expected shellId, got \(String(describing: open))")
        }

        gateway.sessions.revokeServer(serverId: "srv")
        let exec = await gateway.handle(callRequest(
            id: "2",
            session: session,
            tool: AgentToolName.shellExec,
            args: [
                "shellId": .string(shellId),
                "command": .string("echo hi")
            ]
        ))
        XCTAssertEqual(exec.error?.code, .writeGrantRequired)
    }

    func testShellExecRejectsAnotherSession() async throws {
        let shells = FakeShellManager()
        let gateway = makeGateway(
            approver: FakeApprover(result: true),
            servers: [.fixture(id: "srv")],
            shellManager: shells
        )
        let first = try await approveSession(gateway)
        let open = await gateway.handle(callRequest(
            id: "1",
            session: first,
            tool: AgentToolName.shellOpen,
            args: ["server": .string("srv")]
        ))
        guard case .object(let object)? = open.result,
              let shellId = object["shellId"]?.stringValue else {
            return XCTFail("expected shellId, got \(String(describing: open))")
        }

        let second = try await approveSession(gateway)
        let exec = await gateway.handle(callRequest(
            id: "2",
            session: second,
            tool: AgentToolName.shellExec,
            args: [
                "shellId": .string(shellId),
                "command": .string("echo hi")
            ]
        ))
        XCTAssertEqual(exec.error?.code, .unauthorized)
    }

    func testStopRevokesAllSessions() async throws {
        let shells = FakeShellManager()
        let gateway = makeGateway(
            approver: FakeApprover(result: true),
            servers: [.fixture(id: "srv")],
            shellManager: shells
        )
        let session = try await approveSession(gateway)
        gateway.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(shells.closeAllCount, 1)
        XCTAssertTrue(gateway.activeSessions.isEmpty)

        let response = await gateway.handle(callRequest(
            id: "1",
            session: session,
            args: [
                "server": .string("srv"),
                "command": .string("ls"),
                "mode": .string("read")
            ]
        ))
        XCTAssertEqual(response.error?.code, .unauthorized)
    }

    private func approveSession(_ gateway: AgentGateway) async throws -> AgentSessionCredential {
        let hello = await gateway.handle(
            AgentRequest(
                id: "hello",
                op: .hello,
                args: .object(["clientName": .string("Claude Code")])
            )
        )
        guard case .object(let object)? = hello.result,
              let sessionId = object["sessionId"]?.stringValue,
              let token = object["token"]?.stringValue else {
            throw NSError(domain: "AgentGatewayTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "admission was not approved"
            ])
        }
        return AgentSessionCredential(sessionId: sessionId, token: token)
    }

    private func callRequest(
        id: String,
        session: AgentSessionCredential,
        tool: String = AgentToolName.exec,
        args: [String: AgentJSONValue]
    ) -> AgentRequest {
        AgentRequest(
            id: id,
            op: .call,
            sessionId: session.sessionId,
            token: session.token,
            tool: tool,
            args: .object(args)
        )
    }

    private func makeGateway(
        approver: AgentApprovalPresenting,
        approvalWait: TimeInterval = 5,
        servers: [AgentServerSummary] = [],
        shellManager: AgentShellManaging? = FakeShellManager(),
        sessions: AgentSessionStore = AgentSessionStore()
    ) -> AgentGateway {
        AgentGateway(
            execService: FakeExecService(servers: servers),
            approval: approver,
            sessions: sessions,
            audit: FakeAudit(),
            approvalWait: approvalWait,
            socketPath: NSTemporaryDirectory() + "test-\(UUID().uuidString).sock",
            shellManager: shellManager
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

final class MutableClock {
    var now = Date()
}

final class FakeShellManager: AgentShellManaging {
    private(set) var opened: [(serverId: String, sessionId: String)] = []
    private(set) var executed: [(shellId: String, command: String)] = []
    private(set) var closed: [String] = []
    private(set) var closeAllCount = 0
    private(set) var closeAllSessionIds: [String] = []
    private(set) var closeAllServerIds: [String] = []
    private var owners: [String: (sessionId: String, serverId: String)] = [:]
    private var nextShell = 0

    func open(serverId: String, sessionId: String) async throws -> String {
        nextShell += 1
        let shellId = "shell-\(nextShell)"
        owners[shellId] = (sessionId: sessionId, serverId: serverId)
        opened.append((serverId: serverId, sessionId: sessionId))
        return shellId
    }

    func exec(
        shellId: String,
        command: String,
        timeout: TimeInterval
    ) async throws -> AgentShellCommandResult {
        executed.append((shellId: shellId, command: command))
        return AgentShellCommandResult(output: "hi", exitCode: 0)
    }

    func close(shellId: String) async {
        closed.append(shellId)
        owners.removeValue(forKey: shellId)
    }

    func closeAll() async {
        closeAllCount += 1
    }

    func closeAll(sessionId: String) async {
        closeAllSessionIds.append(sessionId)
    }

    func closeAll(serverId: String) async {
        closeAllServerIds.append(serverId)
    }

    func owner(shellId: String) -> (sessionId: String, serverId: String)? {
        owners[shellId]
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
