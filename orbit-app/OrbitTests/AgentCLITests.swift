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
}
