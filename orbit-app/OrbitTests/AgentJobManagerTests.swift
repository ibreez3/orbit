import XCTest
@testable import Orbit
@testable import AgentKit

final class AgentJobManagerTests: XCTestCase {
    func testDuplicateWriteWithSameIdempotencyKeyDoesNotStartSecondJob() async throws {
        let transport = FakeJobExecTransport()
        let suite = "AgentJobManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AgentExecService(
            transport: transport,
            inventory: { [Server.agentFixture(id: "srv", name: "api", host: "10.0.0.1")] },
            exposure: AgentExposureStore(defaults: defaults)
        )
        let request = AgentExecRequest(
            serverQuery: "srv",
            command: "sleep 5",
            mode: .write,
            timeoutMs: 60_000,
            waitMs: 1,
            maxOutputBytes: 1024,
            idempotencyKey: "k1"
        )
        let first = try await service.exec(request)
        let second = try await service.exec(request)
        XCTAssertEqual(first.jobId, second.jobId)
        XCTAssertEqual(transport.startCount, 1)
    }
}

final class FakeJobExecTransport: AgentExecTransport {
    private(set) var startCount = 0

    func agentExec(
        serverId: String,
        command: String,
        timeoutMs: UInt32,
        waitMs: UInt32,
        maxOutputBytes: UInt32
    ) async throws -> AgentExecResult {
        startCount += 1
        return AgentExecResult(
            status: .running,
            serverId: serverId,
            durationMs: 1,
            jobId: "job-1"
        )
    }

    func agentJobStatus(jobId: String) async throws -> AgentJobStatus {
        AgentJobStatus(jobId: jobId, status: .completed, exitCode: 0, durationMs: 1, truncated: false)
    }

    func agentJobOutput(jobId: String, cursor: Int?) async throws -> AgentJobOutput {
        AgentJobOutput(jobId: jobId, chunk: "", nextCursor: cursor ?? 0, eof: true, truncated: false)
    }

    func agentJobCancel(jobId: String) async throws {}
}

extension Server {
    static func agentFixture(id: String, name: String, host: String) -> Server {
        Server(
            id: id,
            name: name,
            host: host,
            port: 22,
            group_name: "",
            auth_type: "password",
            username: "user",
            password: "secret",
            private_key: "",
            key_source: "content",
            key_file_path: "",
            key_passphrase: "",
            credential_group_id: "",
            jump_server_id: "",
            folder_id: nil,
            is_pinned: false,
            pin_order: nil,
            last_connected_at: nil,
            last_attempted_at: nil,
            last_connection_result: nil,
            last_connection_error: nil,
            created_at: "",
            updated_at: ""
        )
    }
}
