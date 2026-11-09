import XCTest
@testable import AgentKit

final class AgentSocketTests: XCTestCase {
    func testPingRoundTripAndSocketPermissions() throws {
        let path = NSTemporaryDirectory() + "orbit-agent-\(UUID().uuidString).sock"
        let server = AgentSocketServer(socketPath: path)
        server.onRequest = { request, respond in
            respond(AgentResponse(
                id: request.id,
                ok: true,
                result: .object(["pong": .bool(true)]),
                error: nil
            ))
        }
        try server.start()
        defer { server.stop() }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let client = AgentSocketClient(socketPath: path)
        try client.connect(timeout: 2)
        defer { client.close() }
        let response = try client.send(
            AgentRequest(id: "1", op: .ping),
            timeout: 2
        )
        XCTAssertEqual(response.result, .object(["pong": .bool(true)]))
    }
}
