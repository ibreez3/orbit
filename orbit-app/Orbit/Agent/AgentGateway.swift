import AgentKit
import Foundation

final class AgentGateway {
    static let shared = AgentGateway()

    private struct PendingAdmission {
        var status: AgentApprovalState
        var session: AgentSessionCredential?
        var error: AgentErrorBody?
    }

    private struct PendingWrite {
        let sessionId: String
        var status: AgentApprovalState
        var error: AgentErrorBody?
    }

    private enum WriteApprovalOutcome {
        case approved
        case pending(requestId: String)
        case denied(AgentErrorBody)
    }

    private let lock = NSLock()
    private let sessions: AgentSessionStore
    private let approvalWait: TimeInterval
    private let socketPath: String
    private var execService: AgentCommandExecuting?
    private var approval: AgentApprovalPresenting?
    private var audit: AgentAuditRecording?
    private var socketServer: AgentSocketServer?
    private var pendingAdmissions: [String: PendingAdmission] = [:]
    private var pendingWrites: [String: PendingWrite] = [:]
    private var jobOwners: [String: String] = [:]

    private init() {
        self.sessions = AgentSessionStore()
        self.approvalWait = 5
        self.socketPath = AgentPaths.socketPath
    }

    init(
        execService: AgentCommandExecuting,
        approval: AgentApprovalPresenting,
        sessions: AgentSessionStore = AgentSessionStore(),
        audit: AgentAuditRecording,
        approvalWait: TimeInterval = 5,
        socketPath: String = AgentPaths.socketPath
    ) {
        self.execService = execService
        self.approval = approval
        self.sessions = sessions
        self.audit = audit
        self.approvalWait = approvalWait
        self.socketPath = socketPath
    }

    func configure(
        execService: AgentCommandExecuting,
        approval: AgentApprovalPresenting,
        audit: AgentAuditRecording
    ) {
        lock.lock()
        self.execService = execService
        self.approval = approval
        self.audit = audit
        lock.unlock()
    }

    var hasActiveSessions: Bool {
        sessions.hasActiveSessions
    }

    var activeSessions: [AgentActiveSession] {
        sessions.activeSessions()
    }

    func start() throws {
        lock.lock()
        if socketServer != nil {
            lock.unlock()
            return
        }
        guard execService != nil, approval != nil, audit != nil else {
            lock.unlock()
            throw AgentGatewayError.notConfigured
        }
        lock.unlock()

        let server = AgentSocketServer(socketPath: socketPath)
        server.onRequest = { [weak self] request, respond in
            guard let self else { return }
            Task {
                respond(await self.handle(request))
            }
        }
        try server.start()
        lock.lock()
        socketServer = server
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let server = socketServer
        socketServer = nil
        pendingAdmissions.removeAll()
        pendingWrites.removeAll()
        jobOwners.removeAll()
        lock.unlock()
        server?.stop()
        sessions.revokeAll()
    }

    func applyServerExposureChange(serverId: String, enabled: Bool) {
        sessions.revokeServer(serverId: serverId)
        if !enabled {
            let exec = execService
            exec?.cancelJobs(serverId: serverId)
        }
    }

    func revokeSession(_ sessionId: String) {
        sessions.revoke(sessionId: sessionId)
    }

    func handle(_ request: AgentRequest) async -> AgentResponse {
        switch request.op {
        case .hello:
            return await handleHello(request)
        case .admissionStatus:
            return handleAdmissionStatus(request)
        case .call:
            return await handleCall(request)
        case .ping:
            return ok(request.id, .object([
                "alive": .bool(true),
                "sessionExpired": .bool(false)
            ]))
        case .revoke:
            return handleRevoke(request)
        }
    }

    private func handleHello(_ request: AgentRequest) async -> AgentResponse {
        let args = request.args?.objectValue ?? [:]
        let agentName = args["clientName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (agentName?.isEmpty == false ? agentName! : "Unknown Agent")
        let clientVersion = args["clientVersion"]?.stringValue ?? ""
        let bridgeVersion = args["bridgeVersion"]?.stringValue ?? ""
        let parentPath = args["parentPath"]?.stringValue ?? ""
        let parentPid = Int32(args["parentPid"]?.numberValue ?? 0)
        let requestId = UUID().uuidString
        let admission = AgentAdmissionRequest(
            requestId: requestId,
            agentName: name,
            clientVersion: clientVersion,
            parentPath: parentPath,
            parentPid: parentPid
        )

        lock.lock()
        guard let approval else {
            lock.unlock()
            return errorResponse(request.id, .orbitUnavailable, "Orbit agent gateway is not configured")
        }
        pendingAdmissions[requestId] = PendingAdmission(status: .pending)
        lock.unlock()

        Task { [weak self] in
            guard let self else { return }
            let approved = await approval.requestAdmission(admission)
            if approved {
                let credential = self.sessions.createSession(agentName: name)
                self.setAdmission(
                    requestId,
                    status: .approved,
                    session: credential,
                    error: nil
                )
                self.record(AgentAuditEvent(
                    type: "agent.admission.approved",
                    sessionId: credential.sessionId,
                    agent: name,
                    result: "approved"
                ))
            } else {
                let body = AgentErrorBody(
                    code: .admissionDenied,
                    message: "The user denied the agent connection"
                )
                self.setAdmission(
                    requestId,
                    status: .denied,
                    session: nil,
                    error: body
                )
                self.record(AgentAuditEvent(
                    type: "agent.admission.denied",
                    agent: name,
                    result: "denied"
                ))
            }
        }

        let deadline = Date().addingTimeInterval(approvalWait)
        while Date() < deadline {
            if let snapshot = admissionSnapshot(requestId), snapshot.status != .pending {
                return admissionResponse(request.id, requestId: requestId, snapshot: snapshot)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return pendingAdmissionResponse(request.id, requestId: requestId)
    }

    private func handleAdmissionStatus(_ request: AgentRequest) -> AgentResponse {
        let requestId = request.args?.objectValue?["requestId"]?.stringValue
        guard let requestId, let snapshot = admissionSnapshot(requestId) else {
            return errorResponse(request.id, .invalidRequest, "Unknown admission request")
        }
        return admissionResponse(request.id, requestId: requestId, snapshot: snapshot)
    }

    private func admissionResponse(
        _ responseId: String,
        requestId: String,
        snapshot: PendingAdmission
    ) -> AgentResponse {
        switch snapshot.status {
        case .pending:
            return pendingAdmissionResponse(responseId, requestId: requestId)
        case .approved:
            guard let session = snapshot.session else {
                return errorResponse(responseId, .admissionDenied, "Missing session credential")
            }
            return ok(responseId, .object([
                "status": .string("approved"),
                "sessionId": .string(session.sessionId),
                "token": .string(session.token)
            ]))
        case .denied, .expired:
            let body = snapshot.error ?? AgentErrorBody(
                code: .admissionDenied,
                message: "The user denied the agent connection"
            )
            return AgentResponse(id: responseId, ok: false, result: nil, error: body)
        }
    }

    private func pendingAdmissionResponse(_ responseId: String, requestId: String) -> AgentResponse {
        ok(responseId, .object([
            "status": .string("pending_approval"),
            "requestId": .string(requestId)
        ]))
    }

    private func handleCall(_ request: AgentRequest) async -> AgentResponse {
        guard let sessionId = request.sessionId,
              let token = request.token else {
            return errorResponse(request.id, .unauthorized, "Missing agent token")
        }
        guard let tool = request.tool else {
            return errorResponse(request.id, .invalidRequest, "Missing agent tool")
        }
        let credential = AgentSessionCredential(sessionId: sessionId, token: token)
        switch sessions.validate(credential) {
        case .valid:
            break
        case .unauthorized:
            return errorResponse(request.id, .unauthorized, "Invalid agent session token")
        case .expired:
            return errorResponse(request.id, .sessionExpired, "The agent session expired")
        }
        sessions.touch(sessionId)

        guard let execService else {
            return errorResponse(request.id, .orbitUnavailable, "Orbit agent gateway is not configured")
        }

        switch tool {
        case AgentToolName.listServers:
            do {
                let value = try AgentJSONValue.encoding(execService.listServers())
                record(AgentAuditEvent(
                    type: "agent.tool.call",
                    sessionId: sessionId,
                    tool: tool,
                    result: "ok"
                ))
                return ok(request.id, .object(["servers": value]))
            } catch {
                return errorResponse(request.id, .invalidRequest, error.localizedDescription)
            }
        case AgentToolName.exec:
            return await handleExec(request, execService: execService, sessionId: sessionId)
        case AgentToolName.approvalStatus:
            return handleWriteApprovalStatus(request, sessionId: sessionId)
        case AgentToolName.jobStatus:
            return await handleJobStatus(request, execService: execService, sessionId: sessionId)
        case AgentToolName.jobOutput:
            return await handleJobOutput(request, execService: execService, sessionId: sessionId)
        case AgentToolName.jobCancel:
            return await handleJobCancel(request, execService: execService, sessionId: sessionId)
        default:
            return errorResponse(request.id, .invalidRequest, "Unsupported agent tool: \(tool)")
        }
    }

    private func handleExec(
        _ request: AgentRequest,
        execService: AgentCommandExecuting,
        sessionId: String
    ) async -> AgentResponse {
        guard let parsed = parseExecRequest(request.args) else {
            return errorResponse(request.id, .invalidRequest, "Invalid orbit_exec arguments")
        }

        let directory = AgentServerDirectory(servers: execService.listServers())
        let server: AgentServerSummary
        switch directory.resolve(parsed.serverQuery) {
        case .resolved(let resolved):
            server = resolved
        case .notFound:
            return errorResponse(request.id, .serverNotFound, "Server not found: \(parsed.serverQuery)")
        case .notExposed:
            return errorResponse(request.id, .serverNotExposed, "Server is not exposed to AI agents")
        case .ambiguous:
            return errorResponse(request.id, .invalidRequest, "Server name is ambiguous; use the server id")
        }

        var requiresWrite = parsed.mode == .write
        var escalated = false
        if case .requireWrite = AgentCommandGuard.evaluate(
            command: parsed.command,
            declaredMode: parsed.mode
        ) {
            requiresWrite = true
            escalated = parsed.mode == .read
        }

        if requiresWrite && !sessions.hasWriteGrant(sessionId: sessionId, serverId: server.id) {
            switch await requestWriteApproval(
                sessionId: sessionId,
                server: server,
                command: parsed.command
            ) {
            case .approved:
                break
            case .pending(let requestId):
                return ok(request.id, .object([
                    "status": .string("pending_approval"),
                    "requestId": .string(requestId),
                    "message": .string("Approve the write operation in Orbit, then retry the same call.")
                ]))
            case .denied(let error):
                return AgentResponse(id: request.id, ok: false, result: nil, error: error)
            }
        }

        var execRequest = parsed
        execRequest.sessionId = sessionId
        execRequest.escalated = escalated
        do {
            let result = try await execService.exec(execRequest)
            if let jobId = result.jobId {
                lock.lock()
                jobOwners[jobId] = sessionId
                lock.unlock()
            }
            record(AgentAuditEvent(
                type: "agent.tool.call",
                sessionId: sessionId,
                serverId: result.serverId,
                tool: AgentToolName.exec,
                command: parsed.command,
                mode: result.mode.rawValue,
                exitCode: result.exitCode,
                durationMs: result.durationMs,
                stdoutBytes: result.stdoutBytes,
                stderrBytes: result.stderrBytes,
                result: result.escalated ? "escalated" : result.status.rawValue
            ))
            let value = try AgentJSONValue.encoding(result)
            return ok(request.id, value)
        } catch let serviceError as AgentServiceError {
            return errorResponse(request.id, serviceError.code, serviceError.message)
        } catch {
            return errorResponse(request.id, .invalidRequest, error.localizedDescription)
        }
    }

    private func requestWriteApproval(
        sessionId: String,
        server: AgentServerSummary,
        command: String
    ) async -> WriteApprovalOutcome {
        let requestId = UUID().uuidString
        lock.lock()
        guard let approval else {
            lock.unlock()
            return .denied(AgentErrorBody(
                code: .orbitUnavailable,
                message: "Orbit agent gateway is not configured"
            ))
        }
        pendingWrites[requestId] = PendingWrite(
            sessionId: sessionId,
            status: .pending,
            error: nil
        )
        lock.unlock()

        let agentName = sessions.agentName(sessionId: sessionId) ?? "AI Agent"
        let writeRequest = AgentWriteRequest(
            requestId: requestId,
            agentName: agentName,
            serverId: server.id,
            serverName: server.name,
            command: command
        )
        Task { [weak self] in
            guard let self else { return }
            let approved = await approval.requestWrite(writeRequest)
            if approved {
                self.sessions.grantWrite(sessionId: sessionId, serverId: server.id)
                self.setWriteApproval(requestId, status: .approved, error: nil)
                self.record(AgentAuditEvent(
                    type: "agent.write.granted",
                    sessionId: sessionId,
                    agent: agentName,
                    serverId: server.id,
                    command: command,
                    result: "approved"
                ))
            } else {
                let body = AgentErrorBody(
                    code: .writeDenied,
                    message: "The user denied write access for this server"
                )
                self.setWriteApproval(requestId, status: .denied, error: body)
                self.record(AgentAuditEvent(
                    type: "agent.write.denied",
                    sessionId: sessionId,
                    agent: agentName,
                    serverId: server.id,
                    command: command,
                    result: "denied"
                ))
            }
        }

        let deadline = Date().addingTimeInterval(approvalWait)
        while Date() < deadline {
            if let snapshot = writeApprovalSnapshot(requestId), snapshot.status != .pending {
                switch snapshot.status {
                case .approved:
                    return .approved
                case .denied, .expired:
                    return .denied(snapshot.error ?? AgentErrorBody(
                        code: .writeDenied,
                        message: "The user denied write access"
                    ))
                case .pending:
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return .pending(requestId: requestId)
    }

    private func handleWriteApprovalStatus(
        _ request: AgentRequest,
        sessionId: String
    ) -> AgentResponse {
        guard let requestId = request.args?.objectValue?["requestId"]?.stringValue,
              let snapshot = writeApprovalSnapshot(requestId) else {
            return errorResponse(request.id, .invalidRequest, "Unknown approval request")
        }
        guard snapshot.sessionId == sessionId else {
            return errorResponse(request.id, .unauthorized, "Approval belongs to another session")
        }
        switch snapshot.status {
        case .pending:
            return ok(request.id, .object([
                "status": .string("pending"),
                "requestId": .string(requestId)
            ]))
        case .approved:
            return ok(request.id, .object([
                "status": .string("approved"),
                "requestId": .string(requestId)
            ]))
        case .denied, .expired:
            return AgentResponse(
                id: request.id,
                ok: false,
                result: nil,
                error: snapshot.error ?? AgentErrorBody(
                    code: .writeDenied,
                    message: "Write approval was denied"
                )
            )
        }
    }

    private func setWriteApproval(
        _ requestId: String,
        status: AgentApprovalState,
        error: AgentErrorBody?
    ) {
        lock.lock()
        if var pending = pendingWrites[requestId] {
            pending.status = status
            pending.error = error
            pendingWrites[requestId] = pending
        }
        lock.unlock()
    }

    private func writeApprovalSnapshot(_ requestId: String) -> PendingWrite? {
        lock.lock()
        defer { lock.unlock() }
        return pendingWrites[requestId]
    }

    private func handleJobStatus(
        _ request: AgentRequest,
        execService: AgentCommandExecuting,
        sessionId: String
    ) async -> AgentResponse {
        guard let jobId = request.args?.objectValue?["jobId"]?.stringValue,
              jobBelongs(jobId, to: sessionId) else {
            return errorResponse(request.id, .unauthorized, "Unknown job for this session")
        }
        do {
            let status = try await execService.jobStatus(jobId: jobId)
            return ok(request.id, try AgentJSONValue.encoding(status))
        } catch let serviceError as AgentServiceError {
            return errorResponse(request.id, serviceError.code, serviceError.message)
        } catch {
            return errorResponse(request.id, .invalidRequest, error.localizedDescription)
        }
    }

    private func handleJobOutput(
        _ request: AgentRequest,
        execService: AgentCommandExecuting,
        sessionId: String
    ) async -> AgentResponse {
        guard let object = request.args?.objectValue,
              let jobId = object["jobId"]?.stringValue,
              jobBelongs(jobId, to: sessionId) else {
            return errorResponse(request.id, .unauthorized, "Unknown job for this session")
        }
        let cursor = Int(object["cursor"]?.numberValue ?? 0)
        do {
            let output = try await execService.jobOutput(jobId: jobId, cursor: cursor)
            return ok(request.id, try AgentJSONValue.encoding(output))
        } catch let serviceError as AgentServiceError {
            return errorResponse(request.id, serviceError.code, serviceError.message)
        } catch {
            return errorResponse(request.id, .invalidRequest, error.localizedDescription)
        }
    }

    private func handleJobCancel(
        _ request: AgentRequest,
        execService: AgentCommandExecuting,
        sessionId: String
    ) async -> AgentResponse {
        guard let jobId = request.args?.objectValue?["jobId"]?.stringValue,
              jobBelongs(jobId, to: sessionId) else {
            return errorResponse(request.id, .unauthorized, "Unknown job for this session")
        }
        do {
            try await execService.jobCancel(jobId: jobId)
            lock.lock()
            jobOwners.removeValue(forKey: jobId)
            lock.unlock()
            return ok(request.id, .object(["status": .string("cancelled")]))
        } catch let serviceError as AgentServiceError {
            return errorResponse(request.id, serviceError.code, serviceError.message)
        } catch {
            return errorResponse(request.id, .invalidRequest, error.localizedDescription)
        }
    }

    private func jobBelongs(_ jobId: String, to sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return jobOwners[jobId] == sessionId
    }

    private func handleRevoke(_ request: AgentRequest) -> AgentResponse {
        guard let sessionId = request.sessionId,
              let token = request.token else {
            return errorResponse(request.id, .invalidRequest, "Missing session")
        }
        let credential = AgentSessionCredential(sessionId: sessionId, token: token)
        guard sessions.validate(credential) == .valid else {
            return errorResponse(request.id, .unauthorized, "Invalid agent session token")
        }
        sessions.revoke(sessionId: sessionId)
        lock.lock()
        jobOwners = jobOwners.filter { $0.value != sessionId }
        lock.unlock()
        record(AgentAuditEvent(
            type: "agent.session.revoked",
            sessionId: sessionId,
            result: "revoked"
        ))
        return ok(request.id, .object(["status": .string("revoked")]))
    }

    private func parseExecRequest(_ args: AgentJSONValue?) -> AgentExecRequest? {
        guard let object = args?.objectValue,
              let server = object["server"]?.stringValue,
              let command = object["command"]?.stringValue,
              !server.isEmpty,
              !command.isEmpty else {
            return nil
        }
        let mode = object["mode"]?.stringValue.flatMap(AgentExecMode.init(rawValue:)) ?? .read
        let timeout = UInt32(object["timeoutMs"]?.numberValue ?? 30_000)
        let wait = UInt32(object["waitMs"]?.numberValue ?? 30_000)
        let maxBytes = UInt32(object["maxOutputBytes"]?.numberValue ?? 262_144)
        return AgentExecRequest(
            serverQuery: server,
            command: command,
            mode: mode,
            timeoutMs: timeout,
            waitMs: wait,
            maxOutputBytes: maxBytes,
            idempotencyKey: object["idempotencyKey"]?.stringValue
        )
    }

    private func setAdmission(
        _ requestId: String,
        status: AgentApprovalState,
        session: AgentSessionCredential?,
        error: AgentErrorBody?
    ) {
        lock.lock()
        pendingAdmissions[requestId] = PendingAdmission(
            status: status,
            session: session,
            error: error
        )
        lock.unlock()
    }

    private func admissionSnapshot(_ requestId: String) -> PendingAdmission? {
        lock.lock()
        defer { lock.unlock() }
        return pendingAdmissions[requestId]
    }

    private func record(_ event: AgentAuditEvent) {
        audit?.record(event)
    }

    private func ok(_ id: String, _ result: AgentJSONValue) -> AgentResponse {
        AgentResponse(id: id, ok: true, result: result, error: nil)
    }

    private func errorResponse(_ id: String, _ code: AgentErrorCode, _ message: String) -> AgentResponse {
        AgentResponse(
            id: id,
            ok: false,
            result: nil,
            error: AgentErrorBody(code: code, message: message)
        )
    }
}

enum AgentGatewayError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Orbit agent gateway is not configured"
        }
    }
}
