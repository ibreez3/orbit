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

    func testSkipsResponsesForOtherRequestIds() throws {
        let path = NSTemporaryDirectory() + "orbit-agent-\(UUID().uuidString).sock"
        let server = AgentSocketServer(socketPath: path)
        server.onRequest = { request, respond in
            respond(AgentResponse(
                id: "another-request",
                ok: true,
                result: .object(["pong": .bool(false)]),
                error: nil
            ))
            respond(AgentResponse(
                id: request.id,
                ok: true,
                result: .object(["pong": .bool(true)]),
                error: nil
            ))
        }
        try server.start()
        defer { server.stop() }

        let client = AgentSocketClient(socketPath: path)
        try client.connect(timeout: 2)
        defer { client.close() }
        let response = try client.send(
            AgentRequest(id: "wanted", op: .ping),
            timeout: 2
        )
        XCTAssertEqual(response.id, "wanted")
        XCTAssertEqual(response.result, .object(["pong": .bool(true)]))
    }

    func testReconnectsAfterServerRestart() throws {
        let path = NSTemporaryDirectory() + "orbit-agent-\(UUID().uuidString).sock"
        let first = AgentSocketServer(socketPath: path)
        first.onRequest = { request, respond in
            respond(AgentResponse(id: request.id, ok: true, result: .object([:]), error: nil))
        }
        try first.start()

        let client = AgentSocketClient(socketPath: path)
        try client.connect(timeout: 2)
        defer { client.close() }
        _ = try client.send(AgentRequest(id: "1", op: .ping), timeout: 2)

        first.stop()
        XCTAssertThrowsError(try client.send(AgentRequest(id: "2", op: .ping), timeout: 1))

        let second = AgentSocketServer(socketPath: path)
        second.onRequest = { request, respond in
            respond(AgentResponse(id: request.id, ok: true, result: .object([:]), error: nil))
        }
        try second.start()
        defer { second.stop() }
        let response = try client.send(AgentRequest(id: "3", op: .ping), timeout: 2)
        XCTAssertEqual(response.id, "3")
    }

    func testRejectsSocketPathLongerThanSockaddrLimit() {
        let path = NSTemporaryDirectory()
            + String(repeating: "x", count: 200)
            + ".sock"
        let server = AgentSocketServer(socketPath: path)
        XCTAssertThrowsError(try server.start()) { error in
            guard case AgentSocketError.pathTooLong = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
