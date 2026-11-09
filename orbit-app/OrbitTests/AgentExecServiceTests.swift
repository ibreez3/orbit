import XCTest
@testable import Orbit
@testable import AgentKit

final class AgentExecServiceTests: XCTestCase {
    func testListServersExcludesDisabledAndMapsFolders() {
        let server = Server.fixture(id: "srv", name: "api", host: "10.0.0.1")
        let suite = "AgentExecServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let exposure = AgentExposureStore(defaults: defaults)
        let service = AgentExecService(
            transport: FakeAgentExecTransport(),
            inventory: { [server] },
            exposure: exposure
        )
        XCTAssertEqual(service.listServers().map(\.id), ["srv"])
        exposure.setEnabled(false, serverId: "srv")
        XCTAssertTrue(service.listServers().isEmpty)
    }

    func testExecRejectsHiddenAndUnknownServers() async {
        let server = Server.fixture(id: "srv", name: "api", host: "10.0.0.1")
        let suite = "AgentExecServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let exposure = AgentExposureStore(defaults: defaults)
        let service = AgentExecService(
            transport: FakeAgentExecTransport(),
            inventory: { [server] },
            exposure: exposure
        )
        let request = AgentExecRequest(
            serverQuery: "srv",
            command: "ls",
            mode: .read,
            timeoutMs: 1000,
            waitMs: 1000,
            maxOutputBytes: 1024,
            idempotencyKey: nil
        )
        let result = try? await service.exec(request)
        XCTAssertEqual(result?.status, .completed)

        exposure.setEnabled(false, serverId: "srv")
        do {
            _ = try await service.exec(request)
            XCTFail("expected not exposed")
        } catch let error as AgentServiceError {
            XCTAssertEqual(error.code, .serverNotExposed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

final class FakeAgentExecTransport: AgentExecTransport {
    private(set) var callCount = 0

    func agentExec(
        serverId: String,
        command: String,
        timeoutMs: UInt32,
        waitMs: UInt32,
        maxOutputBytes: UInt32
    ) async throws -> AgentExecResult {
        callCount += 1
        return AgentExecResult(
            status: .completed,
            serverId: serverId,
            stdout: "ok",
            exitCode: 0,
            durationMs: 1
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

private extension Server {
    static func fixture(id: String, name: String, host: String) -> Server {
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
