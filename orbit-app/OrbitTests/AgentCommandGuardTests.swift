import XCTest
@testable import AgentKit

final class AgentCommandGuardTests: XCTestCase {
    func testReadOnlyCommandsAreAllowed() {
        XCTAssertEqual(
            AgentCommandGuard.evaluate(command: "docker logs --tail 20 api", declaredMode: .read),
            .allowRead
        )
        XCTAssertEqual(
            AgentCommandGuard.evaluate(command: "grep ERROR /var/log/api.log | head -20", declaredMode: .read),
            .allowRead
        )
        XCTAssertEqual(
            AgentCommandGuard.evaluate(command: "systemctl status nginx", declaredMode: .read),
            .allowRead
        )
        XCTAssertEqual(
            AgentCommandGuard.evaluate(command: "docker exec api cat /app/config.yml", declaredMode: .read),
            .allowRead
        )
        XCTAssertEqual(
            AgentCommandGuard.evaluate(command: "ps aux 2>&1 | grep nginx", declaredMode: .read),
            .allowRead
        )
    }

    func testWritePatternsRequireWriteGrant() {
        let commands = [
            "rm -rf /tmp/x",
            "echo x > /tmp/y",
            "sed -i s/a/b/ f",
            "docker restart api",
            "bash -c 'rm x'"
        ]
        for command in commands {
            guard case .requireWrite = AgentCommandGuard.evaluate(command: command, declaredMode: .read) else {
                return XCTFail("expected write for \(command)")
            }
        }
    }

    func testContainerExecInnerCommandIsChecked() {
        guard case .requireWrite = AgentCommandGuard.evaluate(
            command: "docker exec api rm /app/data",
            declaredMode: .read
        ) else {
            return XCTFail("expected write for docker exec with rm")
        }
        guard case .requireWrite = AgentCommandGuard.evaluate(
            command: "docker exec -it api sh",
            declaredMode: .read
        ) else {
            return XCTFail("expected write for interactive docker exec")
        }
    }

    func testWriteDeclaredAlwaysRequiresGrant() {
        guard case .requireWrite = AgentCommandGuard.evaluate(command: "ls", declaredMode: .write) else {
            return XCTFail("declared write must require grant")
        }
    }
}
