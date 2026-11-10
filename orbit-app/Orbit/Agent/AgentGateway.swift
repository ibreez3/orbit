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
    let sessions: AgentSessionStore
    private let approvalWait: TimeInterval
    private let socketPath: String
    private var execService: AgentCommandExecuting?
    private var approval: AgentApprovalPresenting?
    private var audit: AgentAuditRecording?
    private var shellManager: AgentShellManaging?
    private var socketServer: AgentSocketServer?
    private var pendingAdmissions: [String: PendingAdmission] = [:]
    private var pendingWrites: [String: PendingWrite] = [:]
    private var jobOwners: [String: String] = [:]
    private var jobServers: [String: String] = [:]
    private var disabledServers: Set<String> = []
    private var serverGenerations: [String: UInt64] = [:]
    private var gatewayGeneration: UInt64 = 0

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
        socketPath: String = AgentPaths.socketPath,
        shellManager: AgentShellManaging? = nil
    ) {
        self.execService = execService
        self.approval = approval
        self.sessions = sessions
        self.audit = audit
        self.approvalWait = approvalWait
        self.socketPath = socketPath
        self.shellManager = shellManager
    }

    func configure(
        execService: AgentCommandExecuting,
        approval: AgentApprovalPresenting,
        audit: AgentAuditRecording,
        shellManager: AgentShellManaging? = nil
    ) {
        lock.lock()
        self.execService = execService
        self.approval = approval
        self.audit = audit
        let previous = self.shellManager
        let manager = shellManager
            ?? previous
            ?? AgentShellManager(transport: OrbitBridge.shared, sessions: sessions)
        self.shellManager = manager
        lock.unlock()
        if let previous, previous !== manager {
            Task { await previous.closeAll() }
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return socketServer != nil
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
        gatewayGeneration &+= 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        gatewayGeneration &+= 1
        let server = socketServer
        let exec = execService
        let shells = shellManager
        let jobs = Array(jobOwners.keys)
        socketServer = nil
        pendingAdmissions.removeAll()
        pendingWrites.removeAll()
        jobOwners.removeAll()
        jobServers.removeAll()
        lock.unlock()
        server?.stop()
        sessions.revokeAll()
        cancelJobs(jobs, using: exec)
        Task { await shells?.closeAll() }
    }

    func applyServerExposureChange(serverId: String, enabled: Bool) {
        lock.lock()
        if enabled {
            disabledServers.remove(serverId)
        } else {
            disabledServers.insert(serverId)
        }
        serverGenerations[serverId, default: 0] &+= 1
        let exec = execService
        let shells = shellManager
        let jobs = jobServers
            .filter { $0.value == serverId }
            .map(\.key)
        for jobId in jobs {
            jobOwners.removeValue(forKey: jobId)
            jobServers.removeValue(forKey: jobId)
        }
        lock.unlock()

        sessions.revokeServer(serverId: serverId)
        if !enabled {
            cancelJobs(jobs, using: exec)
            Task { await shells?.closeAll(serverId: serverId) }
        }
    }

    func revokeSession(_ sessionId: String) {
        lock.lock()
        let exec = execService
        let shells = shellManager
        let jobs = jobOwners
            .filter { $0.value == sessionId }
            .map(\.key)
        for jobId in jobs {
            jobOwners.removeValue(forKey: jobId)
            jobServers.removeValue(forKey: jobId)
        }
        lock.unlock()
        sessions.revoke(sessionId: sessionId)
        cancelJobs(jobs, using: exec)
        Task { await shells?.closeAll(sessionId: sessionId) }
    }

    private func cancelJobs(_ jobs: [String], using exec: AgentCommandExecuting?) {
        guard let exec, !jobs.isEmpty else { return }
        Task {
            for jobId in jobs {
                try? await exec.jobCancel(jobId: jobId)
            }
        }
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
        let parentPid = AgentNumeric.int32(args["parentPid"]?.numberValue, default: 0)
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
        let generation = gatewayGeneration
        lock.unlock()

        Task { [weak self] in
            guard let self else { return }
            let approved = await approval.requestAdmission(admission)
            guard self.isCurrentGeneration(generation) else {
                let body = AgentErrorBody(
                    code: .admissionDenied,
                    message: "Orbit stopped the agent gateway before approval completed"
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
                return
            }
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
            let shells = currentShellManager()
            lock.lock()
            let exec = execService
            let jobs = jobOwners
                .filter { $0.value == sessionId }
                .map(\.key)
            for jobId in jobs {
                jobOwners.removeValue(forKey: jobId)
                jobServers.removeValue(forKey: jobId)
            }
            lock.unlock()
            cancelJobs(jobs, using: exec)
            Task { await shells?.closeAll(sessionId: sessionId) }
            return errorResponse(request.id, .sessionExpired, "The agent session expired")
        }
        sessions.touch(sessionId)

        guard let execService else {
            return errorResponse(request.id, .orbitUnavailable, "Orbit agent gateway is not configured")
        }

        switch tool {
        case AgentToolName.listServers:
            do {
                lock.lock()
                let disabled = disabledServers
                lock.unlock()
                let servers = execService.listServers().filter { !disabled.contains($0.id) }
                let value = try AgentJSONValue.encoding(servers)
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
        case AgentToolName.shellOpen:
            return await handleShellOpen(request, execService: execService, sessionId: sessionId)
        case AgentToolName.shellExec:
            return await handleShellExec(request, sessionId: sessionId)
        case AgentToolName.shellClose:
            return await handleShellClose(request, sessionId: sessionId)
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

        let server: AgentServerSummary
        switch resolveServer(parsed.serverQuery, execService: execService) {
        case .success(let resolved):
            server = resolved
        case .failure(let error):
            return AgentResponse(id: request.id, ok: false, result: nil, error: error)
        }

        if isServerDisabled(server.id) {
            return errorResponse(request.id, .serverNotExposed, "Server is not exposed to AI agents")
        }
        let generation = currentGeneration()
        let serverGeneration = currentServerGeneration(server.id)

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

        guard isCurrentGeneration(generation),
              isCurrentServerGeneration(serverGeneration, serverId: server.id),
              !isServerDisabled(server.id) else {
            let code: AgentErrorCode = isCurrentGeneration(generation)
                ? .serverNotExposed
                : .orbitUnavailable
            return errorResponse(
                request.id,
                code,
                "The server is no longer available to AI agents"
            )
        }

        var execRequest = parsed
        execRequest.sessionId = sessionId
        execRequest.escalated = escalated
        do {
            let result = try await execService.exec(execRequest)
            let allowed: Bool
            lock.lock()
            allowed = gatewayGeneration == generation
                && serverGenerations[server.id, default: 0] == serverGeneration
                && !disabledServers.contains(server.id)
            if allowed, let jobId = result.jobId {
                jobOwners[jobId] = sessionId
                jobServers[jobId] = server.id
            }
            lock.unlock()

            guard allowed else {
                if let jobId = result.jobId {
                    try? await execService.jobCancel(jobId: jobId)
                }
                let code: AgentErrorCode = isCurrentGeneration(generation)
                    ? .serverNotExposed
                    : .orbitUnavailable
                return errorResponse(
                    request.id,
                    code,
                    "The server is no longer available to AI agents"
                )
            }
            if let jobId = result.jobId, result.status == .running {
                sessions.markJobActive(sessionId: sessionId, jobId: jobId)
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

    private func handleShellOpen(
        _ request: AgentRequest,
        execService: AgentCommandExecuting,
        sessionId: String
    ) async -> AgentResponse {
        guard let manager = currentShellManager() else {
            return errorResponse(request.id, .orbitUnavailable, "Orbit agent gateway is not configured")
        }
        guard let serverQuery = request.args?.objectValue?["server"]?.stringValue,
              !serverQuery.isEmpty else {
            return errorResponse(request.id, .invalidRequest, "orbit_shell_open requires a server")
        }

        let server: AgentServerSummary
        switch resolveServer(serverQuery, execService: execService) {
        case .success(let resolved):
            server = resolved
        case .failure(let error):
            return AgentResponse(id: request.id, ok: false, result: nil, error: error)
        }
        if isServerDisabled(server.id) {
            return errorResponse(request.id, .serverNotExposed, "Server is not exposed to AI agents")
        }
        let generation = currentGeneration()
        let serverGeneration = currentServerGeneration(server.id)

        if !sessions.hasWriteGrant(sessionId: sessionId, serverId: server.id) {
            switch await requestWriteApproval(
                sessionId: sessionId,
                server: server,
                command: "open shell"
            ) {
            case .approved:
                break
            case .pending(let requestId):
                return ok(request.id, .object([
                    "status": .string("pending_approval"),
                    "requestId": .string(requestId),
                    "message": .string("Approve shell access in Orbit, then retry the same call.")
                ]))
            case .denied(let error):
                return AgentResponse(id: request.id, ok: false, result: nil, error: error)
            }
        }

        guard isCurrentGeneration(generation),
              isCurrentServerGeneration(serverGeneration, serverId: server.id),
              !isServerDisabled(server.id),
              isServerExposed(server.id) else {
            let code: AgentErrorCode = isCurrentGeneration(generation)
                ? .serverNotExposed
                : .orbitUnavailable
            return errorResponse(
                request.id,
                code,
                "The server is no longer available to AI agents"
            )
        }

        do {
            let shellId = try await manager.open(serverId: server.id, sessionId: sessionId)
            guard isCurrentGeneration(generation),
                  isCurrentServerGeneration(serverGeneration, serverId: server.id),
                  !isServerDisabled(server.id),
                  isServerExposed(server.id) else {
                await manager.close(shellId: shellId)
                let code: AgentErrorCode = isCurrentGeneration(generation)
                    ? .serverNotExposed
                    : .orbitUnavailable
                return errorResponse(
                    request.id,
                    code,
                    "The server is no longer available to AI agents"
                )
            }
            record(AgentAuditEvent(
                type: "agent.shell.opened",
                sessionId: sessionId,
                agent: sessions.agentName(sessionId: sessionId),
                serverId: server.id,
                command: "open shell",
                mode: "write",
                result: "opened"
            ))
            return ok(request.id, .object([
                "shellId": .string(shellId),
                "serverId": .string(server.id),
                "serverName": .string(server.name)
            ]))
        } catch let shellError as AgentShellError {
            return errorResponse(request.id, shellError.code, shellError.errorDescription ?? "Shell error")
        } catch {
            return errorResponse(request.id, .orbitUnavailable, error.localizedDescription)
        }
    }

    private func handleShellExec(
        _ request: AgentRequest,
        sessionId: String
    ) async -> AgentResponse {
        guard let manager = currentShellManager() else {
            return errorResponse(request.id, .orbitUnavailable, "Orbit agent gateway is not configured")
        }
        guard let object = request.args?.objectValue,
              let shellId = object["shellId"]?.stringValue,
              let command = object["command"]?.stringValue,
              !command.isEmpty else {
            return errorResponse(request.id, .invalidRequest, "orbit_shell_exec requires shellId and command")
        }
        guard let owner = manager.owner(shellId: shellId),
              owner.sessionId == sessionId else {
            return errorResponse(request.id, .unauthorized, "Unknown shell for this session")
        }
        guard sessions.hasWriteGrant(sessionId: sessionId, serverId: owner.serverId) else {
            return errorResponse(request.id, .writeGrantRequired, "Write access for this server was revoked")
        }

        let timeoutMs = AgentNumeric.uint32(
            object["timeoutMs"]?.numberValue,
            default: 50_000,
            range: 1...50_000
        )
        let timeout = Double(timeoutMs) / 1000
        do {
            let result = try await manager.exec(
                shellId: shellId,
                command: command,
                timeout: timeout
            )
            record(AgentAuditEvent(
                type: "agent.shell.exec",
                sessionId: sessionId,
                serverId: owner.serverId,
                tool: AgentToolName.shellExec,
                command: command,
                mode: "write",
                exitCode: result.exitCode,
                result: "completed"
            ))
            return ok(request.id, .object([
                "output": .string(result.output),
                "exitCode": .number(Double(result.exitCode)),
                "truncated": .bool(result.truncated)
            ]))
        } catch let shellError as AgentShellError {
            return errorResponse(request.id, shellError.code, shellError.errorDescription ?? "Shell error")
        } catch {
            return errorResponse(request.id, .invalidRequest, error.localizedDescription)
        }
    }

    private func handleShellClose(
        _ request: AgentRequest,
        sessionId: String
    ) async -> AgentResponse {
        guard let manager = currentShellManager() else {
            return errorResponse(request.id, .orbitUnavailable, "Orbit agent gateway is not configured")
        }
        guard let shellId = request.args?.objectValue?["shellId"]?.stringValue else {
            return errorResponse(request.id, .invalidRequest, "orbit_shell_close requires shellId")
        }
        guard let owner = manager.owner(shellId: shellId),
              owner.sessionId == sessionId else {
            return errorResponse(request.id, .unauthorized, "Unknown shell for this session")
        }

        await manager.close(shellId: shellId)
        record(AgentAuditEvent(
            type: "agent.shell.closed",
            sessionId: sessionId,
            serverId: owner.serverId,
            command: "close shell",
            mode: "write",
            result: "closed"
        ))
        return ok(request.id, .object(["status": .string("closed")]))
    }

    private func resolveServer(
        _ query: String,
        execService: AgentCommandExecuting
    ) -> Result<AgentServerSummary, AgentErrorBody> {
        let directory = AgentServerDirectory(servers: execService.listServers())
        switch directory.resolve(query) {
        case .resolved(let server):
            return .success(server)
        case .notFound:
            return .failure(AgentErrorBody(
                code: .serverNotFound,
                message: "Server not found: \(query)"
            ))
        case .notExposed:
            return .failure(AgentErrorBody(
                code: .serverNotExposed,
                message: "Server is not exposed to AI agents"
            ))
        case .ambiguous:
            return .failure(AgentErrorBody(
                code: .invalidRequest,
                message: "Server name is ambiguous; use the server id"
            ))
        }
    }

    private func isServerDisabled(_ serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disabledServers.contains(serverId)
    }

    private func isServerExposed(_ serverId: String) -> Bool {
        lock.lock()
        let exec = execService
        let disabled = disabledServers.contains(serverId)
        lock.unlock()
        guard !disabled, let exec else { return false }
        return exec.listServers().contains { $0.id == serverId }
    }

    private func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return gatewayGeneration
    }

    private func currentServerGeneration(_ serverId: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return serverGenerations[serverId, default: 0]
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gatewayGeneration == generation
    }

    private func isCurrentServerGeneration(_ generation: UInt64, serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return serverGenerations[serverId, default: 0] == generation
    }

    private func currentShellManager() -> AgentShellManaging? {
        lock.lock()
        defer { lock.unlock() }
        return shellManager
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
        let generation = gatewayGeneration
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
            guard self.isCurrentGeneration(generation),
                  self.sessions.agentName(sessionId: sessionId) != nil,
                  self.isServerExposed(server.id) else {
                let body = AgentErrorBody(
                    code: .writeDenied,
                    message: "Write approval was revoked before it was granted"
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
                return
            }
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
            if status.status != .running {
                sessions.markJobFinished(sessionId: sessionId, jobId: jobId)
            }
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
        let cursor = AgentNumeric.int(
            object["cursor"]?.numberValue,
            default: 0,
            range: 0...Int.max
        )
        do {
            let output = try await execService.jobOutput(jobId: jobId, cursor: cursor)
            if output.eof {
                sessions.markJobFinished(sessionId: sessionId, jobId: jobId)
            }
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
            jobServers.removeValue(forKey: jobId)
            lock.unlock()
            sessions.markJobFinished(sessionId: sessionId, jobId: jobId)
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
        let shells = currentShellManager()
        sessions.revoke(sessionId: sessionId)
        lock.lock()
        jobOwners = jobOwners.filter { $0.value != sessionId }
        lock.unlock()
        Task { await shells?.closeAll(sessionId: sessionId) }
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
        let timeout = AgentNumeric.uint32(
            object["timeoutMs"]?.numberValue,
            default: 30_000,
            range: 1...300_000
        )
        let wait = AgentNumeric.uint32(
            object["waitMs"]?.numberValue,
            default: 30_000,
            range: 1...50_000
        )
        let maxBytes = AgentNumeric.uint32(
            object["maxOutputBytes"]?.numberValue,
            default: 262_144,
            range: 1...1_048_576
        )
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

private extension AgentShellError {
    var code: AgentErrorCode {
        switch self {
        case .writeRequired:
            return .writeGrantRequired
        case .shellNotFound:
            return .shellNotFound
        case .busy:
            return .invalidRequest
        case .timeout:
            return .shellTimeout
        case .closed:
            return .shellNotFound
        case .transport:
            return .orbitUnavailable
        }
    }
}
