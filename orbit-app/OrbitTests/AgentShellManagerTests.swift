import XCTest
@testable import Orbit
@testable import AgentKit

final class AgentShellManagerTests: XCTestCase {
    func testShellExecReturnsOutputAndExitCode() async throws {
        let transport = FakeShellTransport()
        let manager = AgentShellManager(transport: transport, sessions: AgentSessionStore())
        let session = manager.sessions.createSession(agentName: "Claude Code")
        manager.sessions.grantWrite(sessionId: session.sessionId, serverId: "srv")
        let shellId = try await manager.open(serverId: "srv", sessionId: session.sessionId)
        let result = try await manager.exec(shellId: shellId, command: "echo hi", timeout: 2)
        XCTAssertEqual(result.output, "hi")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testShellOpenRequiresWriteGrant() async {
        let manager = AgentShellManager(transport: FakeShellTransport(), sessions: AgentSessionStore())
        let session = manager.sessions.createSession(agentName: "Claude Code")
        do {
            _ = try await manager.open(serverId: "srv", sessionId: session.sessionId)
            XCTFail("expected writeRequired")
        } catch let error as AgentShellError {
            XCTAssertEqual(error, .writeRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testShellExecTimesOutWhenMarkerNeverArrives() async throws {
        let transport = FakeShellTransport(emitsCompletion: false)
        let manager = AgentShellManager(transport: transport, sessions: AgentSessionStore())
        let session = manager.sessions.createSession(agentName: "Claude Code")
        manager.sessions.grantWrite(sessionId: session.sessionId, serverId: "srv")
        let shellId = try await manager.open(serverId: "srv", sessionId: session.sessionId)
        do {
            _ = try await manager.exec(shellId: shellId, command: "sleep 1", timeout: 0.05)
            XCTFail("expected timeout")
        } catch let error as AgentShellError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

final class FakeShellTransport: AgentShellTransport {
    let emitsCompletion: Bool
    private var handlers: [String: (Data) -> Void] = [:]
    private var nextShell = 0
    private(set) var written: [String: String] = [:]
    private(set) var closed: [String] = []

    init(emitsCompletion: Bool = true) {
        self.emitsCompletion = emitsCompletion
    }

    func connect(serverId: String) async throws -> String {
        "base-\(serverId)"
    }

    func openShell(baseSessionId: String) async throws -> String {
        nextShell += 1
        return "shell-\(nextShell)"
    }

    func write(shellId: String, data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        written[shellId, default: ""] += text
        guard emitsCompletion,
              let uuid = Self.sentinelUUID(in: text),
              let handler = handlers[shellId] else {
            return
        }
        handler(Data("hi\n".utf8))
        handler(Data("__ORBIT_DONE_\(uuid)__0\n".utf8))
    }

    func close(shellId: String) async {
        closed.append(shellId)
    }

    func setOutputHandler(shellId: String, handler: @escaping (Data) -> Void) {
        handlers[shellId] = handler
    }

    private static func sentinelUUID(in text: String) -> String? {
        let pattern = #"__ORBIT_DONE_([A-Za-z0-9-]+)__%s"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
