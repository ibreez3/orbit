import XCTest
@testable import AgentKit

final class AgentCLITests: XCTestCase {
    func testServersPrintsJSONAfterAuth() throws {
        let client = FakeGatewayClient(admission: .approved(.init(sessionId: "s", token: "t")))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = AgentSessionFileStore(directory: directory)
        var output: [String] = []

        try AgentCLI.run(
            arguments: ["auth", "--client", "Claude Code"],
            client: client,
            sessions: sessions,
            stdout: { output.append($0) },
            stderr: { _ in }
        )
        try AgentCLI.run(
            arguments: ["servers", "--session", "s"],
            client: client,
            sessions: sessions,
            stdout: { output.append($0) },
            stderr: { _ in }
        )

        XCTAssertTrue(output.joined().contains("servers"))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("s.json").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExecRequiresASession() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = AgentSessionFileStore(directory: directory)
        XCTAssertThrowsError(try AgentCLI.run(
            arguments: ["exec", "--server", "srv", "--", "ls"],
            client: FakeGatewayClient(),
            sessions: sessions,
            stdout: { _ in },
            stderr: { _ in }
        ))
    }

    func testJobStatusUsesTheJobToolAndPrintsResult() throws {
        let client = FakeGatewayClient()
        let sessions = try makeSessions()
        try saveSession(sessions)
        var output: [String] = []

        try AgentCLI.run(
            arguments: ["job", "status", "--session", "s", "--job", "j"],
            client: client,
            sessions: sessions,
            stdout: { output.append($0) },
            stderr: { _ in }
        )

        XCTAssertEqual(client.lastTool, AgentToolName.jobStatus)
        XCTAssertEqual(client.lastArgs?.objectValue?["jobId"]?.stringValue, "j")
        XCTAssertTrue(output.joined().contains("running"))
    }

    func testJobOutputPassesTheCursor() throws {
        let client = FakeGatewayClient()
        let sessions = try makeSessions()
        try saveSession(sessions)

        try AgentCLI.run(
            arguments: ["job", "output", "--session", "s", "--job", "j", "--cursor", "5"],
            client: client,
            sessions: sessions,
            stdout: { _ in },
            stderr: { _ in }
        )

        XCTAssertEqual(client.lastTool, AgentToolName.jobOutput)
        XCTAssertEqual(client.lastArgs?.objectValue?["cursor"]?.numberValue, 5)
    }

    func testJobCancelUsesTheJobCancelTool() throws {
        let client = FakeGatewayClient()
        let sessions = try makeSessions()
        try saveSession(sessions)

        try AgentCLI.run(
            arguments: ["job", "cancel", "--session", "s", "--job", "j"],
            client: client,
            sessions: sessions,
            stdout: { _ in },
            stderr: { _ in }
        )

        XCTAssertEqual(client.lastTool, AgentToolName.jobCancel)
        XCTAssertEqual(client.lastArgs?.objectValue?["jobId"]?.stringValue, "j")
    }

    func testShellOpenExecCloseWritesJSON() throws {
        let client = FakeGatewayClient()
        let sessions = try makeSessions()
        try saveSession(sessions)
        var output: [String] = []

        try AgentCLI.run(
            arguments: ["shell", "open", "--server", "srv", "--session", "s"],
            client: client,
            sessions: sessions,
            stdout: { output.append($0) },
            stderr: { _ in }
        )
        XCTAssertTrue(output.joined().contains("shellId"))
        XCTAssertEqual(client.lastTool, AgentToolName.shellOpen)
        XCTAssertEqual(client.lastArgs?.objectValue?["server"]?.stringValue, "srv")

        output.removeAll()
        try AgentCLI.run(
            arguments: [
                "shell", "exec", "--shell", "shell-1", "--session", "s", "--", "echo", "hi"
            ],
            client: client,
            sessions: sessions,
            stdout: { output.append($0) },
            stderr: { _ in }
        )
        XCTAssertTrue(output.joined().contains("output"))
        XCTAssertEqual(client.lastTool, AgentToolName.shellExec)
        XCTAssertEqual(client.lastArgs?.objectValue?["shellId"]?.stringValue, "shell-1")
        XCTAssertEqual(client.lastArgs?.objectValue?["command"]?.stringValue, "echo hi")

        output.removeAll()
        try AgentCLI.run(
            arguments: ["shell", "close", "--shell", "shell-1", "--session", "s"],
            client: client,
            sessions: sessions,
            stdout: { output.append($0) },
            stderr: { _ in }
        )
        XCTAssertEqual(client.lastTool, AgentToolName.shellClose)
        XCTAssertEqual(client.lastArgs?.objectValue?["shellId"]?.stringValue, "shell-1")
    }

    private func makeSessions() throws -> AgentSessionFileStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AgentSessionFileStore(directory: directory)
    }

    private func saveSession(_ sessions: AgentSessionFileStore) throws {
        _ = try sessions.save(
            AgentSessionCredential(sessionId: "s", token: "t"),
            clientName: "test"
        )
    }
}
