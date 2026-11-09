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
}

struct AgentServiceError: LocalizedError {
    let code: AgentErrorCode
    let message: String

    var errorDescription: String? { message }
}

final class AgentExecService: AgentCommandExecuting {
    private let transport: AgentExecTransport
    private let inventory: () -> [Server]
    private let organization: () -> ServerOrganizationSnapshot
    private let exposure: AgentExposureStore

    init(
        transport: AgentExecTransport,
        inventory: @escaping () -> [Server],
        organization: @escaping () -> ServerOrganizationSnapshot = { .empty },
        exposure: AgentExposureStore
    ) {
        self.transport = transport
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

        var result = try await transport.agentExec(
            serverId: serverID,
            command: request.command,
            timeoutMs: request.timeoutMs,
            waitMs: request.waitMs,
            maxOutputBytes: request.maxOutputBytes
        )
        result.mode = request.mode
        return result
    }

    func jobStatus(jobId: String) async throws -> AgentJobStatus {
        throw AgentServiceError(
            code: .invalidRequest,
            message: "Job polling is not available yet"
        )
    }

    func jobOutput(jobId: String, cursor: Int?) async throws -> AgentJobOutput {
        throw AgentServiceError(
            code: .invalidRequest,
            message: "Job polling is not available yet"
        )
    }

    func jobCancel(jobId: String) async throws {
        throw AgentServiceError(
            code: .invalidRequest,
            message: "Job polling is not available yet"
        )
    }

    func cancelJobs(serverId: String) {
        // Task 16 wires the job manager.
    }
}

extension OrbitBridge: AgentExecTransport {}
