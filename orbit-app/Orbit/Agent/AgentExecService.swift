import AgentKit
import Foundation

protocol AgentExecTransport {
    func agentExec(
        serverId: String,
        command: String,
        timeoutMs: UInt32,
        waitMs: UInt32,
        maxOutputBytes: UInt32
    ) async throws -> AgentExecResult
    func agentJobStatus(jobId: String) async throws -> AgentJobStatus
    func agentJobOutput(jobId: String, cursor: Int?) async throws -> AgentJobOutput
    func agentJobCancel(jobId: String) async throws
}

struct AgentServiceError: LocalizedError {
    let code: AgentErrorCode
    let message: String

    var errorDescription: String? { message }
}

final class AgentExecService: AgentCommandExecuting {
    private struct IdempotencyEntry {
        let jobId: String
        let createdAt: Date
    }

    private let transport: AgentExecTransport
    private let jobManager: AgentJobManager
    private let inventory: () -> [Server]
    private let organization: () -> ServerOrganizationSnapshot
    private let exposure: AgentExposureStore
    private let idempotencyLock = NSLock()
    private var idempotencyEntries: [String: IdempotencyEntry] = [:]
    private var inFlight: [String: Task<AgentExecResult, Error>] = [:]

    init(
        transport: AgentExecTransport,
        inventory: @escaping () -> [Server],
        organization: @escaping () -> ServerOrganizationSnapshot = { .empty },
        exposure: AgentExposureStore
    ) {
        self.transport = transport
        self.jobManager = AgentJobManager(transport: transport)
        self.inventory = inventory
        self.organization = organization
        self.exposure = exposure
    }

    func listServers() -> [AgentServerSummary] {
        allServerSummaries()
            .filter(\.aiEnabled)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func allServerSummaries() -> [AgentServerSummary] {
        let servers = inventory()
        let snapshot = organization()
        let projection = ServerTreeProjection(snapshot: snapshot, servers: servers)
        let tagsByID = Dictionary(uniqueKeysWithValues: snapshot.tags.map { ($0.id, $0.name) })
        let tagLinksByServer = Dictionary(grouping: snapshot.tag_links, by: \.server_id)

        return servers.map { server in
            let folder = server.folder_id.flatMap { projection.path(forFolderId: $0) }
            let tags = (tagLinksByServer[server.id] ?? [])
                .compactMap { tagsByID[$0.tag_id] }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return AgentServerSummary(
                id: server.id,
                name: server.name,
                host: server.host,
                port: server.port,
                username: server.username,
                folder: folder,
                tags: tags,
                aiEnabled: exposure.isEnabled(serverId: server.id)
            )
        }
    }

    func exec(_ request: AgentExecRequest) async throws -> AgentExecResult {
        let directory = AgentServerDirectory(servers: allServerSummaries())
        let serverID: String
        switch directory.resolve(request.serverQuery) {
        case .resolved(let server):
            serverID = server.id
        case .notFound:
            throw AgentServiceError(
                code: .serverNotFound,
                message: "Server not found: \(request.serverQuery)"
            )
        case .notExposed:
            throw AgentServiceError(
                code: .serverNotExposed,
                message: "Server is not exposed to AI agents"
            )
        case .ambiguous:
            throw AgentServiceError(
                code: .invalidRequest,
                message: "Server name is ambiguous; use the server id"
            )
        }

        let idempotencyKey = idempotencyKey(for: request, serverID: serverID)
        if let idempotencyKey, let jobID = existingJob(for: idempotencyKey) {
            return AgentExecResult(
                status: .running,
                serverId: serverID,
                durationMs: 0,
                jobId: jobID,
                mode: request.mode,
                escalated: request.escalated
            )
        }

        if let idempotencyKey {
            let task: Task<AgentExecResult, Error>
            let owner: Bool
            idempotencyLock.lock()
            if let existing = inFlight[idempotencyKey] {
                task = existing
                owner = false
            } else {
                task = Task {
                    try await self.transport.agentExec(
                        serverId: serverID,
                        command: request.command,
                        timeoutMs: request.timeoutMs,
                        waitMs: request.waitMs,
                        maxOutputBytes: request.maxOutputBytes
                    )
                }
                inFlight[idempotencyKey] = task
                owner = true
            }
            idempotencyLock.unlock()

            do {
                var result = try await task.value
                if owner {
                    if let jobID = result.jobId {
                        recordJob(jobID, for: idempotencyKey)
                    }
                    idempotencyLock.lock()
                    inFlight.removeValue(forKey: idempotencyKey)
                    idempotencyLock.unlock()
                }
                result.mode = request.mode
                result.escalated = request.escalated
                return result
            } catch {
                if owner {
                    idempotencyLock.lock()
                    inFlight.removeValue(forKey: idempotencyKey)
                    idempotencyLock.unlock()
                }
                throw error
            }
        }

        var result = try await transport.agentExec(
            serverId: serverID,
            command: request.command,
            timeoutMs: request.timeoutMs,
            waitMs: request.waitMs,
            maxOutputBytes: request.maxOutputBytes
        )
        result.mode = request.mode
        result.escalated = request.escalated
        return result
    }

    func jobStatus(jobId: String) async throws -> AgentJobStatus {
        try await jobManager.status(jobId: jobId)
    }

    func jobOutput(jobId: String, cursor: Int?) async throws -> AgentJobOutput {
        try await jobManager.output(jobId: jobId, cursor: cursor)
    }

    func jobCancel(jobId: String) async throws {
        try await jobManager.cancel(jobId: jobId)
    }

    func cancelJobs(serverId: String) {
        // Job ownership and cancellation are enforced by the gateway.
    }

    private func idempotencyKey(for request: AgentExecRequest, serverID: String) -> String? {
        let session = request.sessionId ?? ""
        if let key = request.idempotencyKey, !key.isEmpty {
            return "\(session)|\(key)"
        }
        if request.mode == .write {
            return "cmd|\(session)|\(serverID)|\(request.command)"
        }
        return nil
    }

    private func existingJob(for key: String) -> String? {
        idempotencyLock.lock()
        defer { idempotencyLock.unlock() }
        guard let entry = idempotencyEntries[key] else { return nil }
        if Date().timeIntervalSince(entry.createdAt) > 60 {
            idempotencyEntries.removeValue(forKey: key)
            return nil
        }
        return entry.jobId
    }

    private func recordJob(_ jobID: String, for key: String) {
        idempotencyLock.lock()
        defer { idempotencyLock.unlock() }
        let cutoff = Date().addingTimeInterval(-60)
        idempotencyEntries = idempotencyEntries.filter { $0.value.createdAt >= cutoff }
        idempotencyEntries[key] = IdempotencyEntry(jobId: jobID, createdAt: Date())
    }
}

final class AgentJobManager {
    private let transport: AgentExecTransport

    init(transport: AgentExecTransport) {
        self.transport = transport
    }

    func status(jobId: String) async throws -> AgentJobStatus {
        try await transport.agentJobStatus(jobId: jobId)
    }

    func output(jobId: String, cursor: Int?) async throws -> AgentJobOutput {
        try await transport.agentJobOutput(jobId: jobId, cursor: cursor)
    }

    func cancel(jobId: String) async throws {
        try await transport.agentJobCancel(jobId: jobId)
    }
}

extension OrbitBridge: AgentExecTransport {}
