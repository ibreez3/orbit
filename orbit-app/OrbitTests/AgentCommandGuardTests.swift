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

    func testDockerExecOptionsDoNotHideInnerCommand() {
        let commands = [
            "docker exec -u root api rm -rf /app/data",
            "docker exec --user root api rm -rf /app/data",
            "docker exec -e FOO=bar api rm -rf /app/data",
            "docker exec --env FOO=bar api rm -rf /app/data",
            "docker exec --env-file /tmp/env api rm -rf /app/data",
            "docker exec -w /app api rm -rf /data",
            "docker exec --detach-keys ctrl-a api rm -rf /data"
        ]
        for command in commands {
            guard case .requireWrite = AgentCommandGuard.evaluate(command: command, declaredMode: .read) else {
                return XCTFail("expected write for \(command)")
            }
        }
        XCTAssertEqual(
            AgentCommandGuard.evaluate(
                command: "docker exec -u root api cat /app/config.yml",
                declaredMode: .read
            ),
            .allowRead
        )
    }

    func testCommandSubstitutionRequiresWrite() {
        let commands = [
            "echo $(rm -rf /tmp/x)",
            "echo `rm -rf /tmp/x`",
            "echo \"$(rm -rf /tmp/x)\"",
            "cat <(rm -rf /tmp/x)"
        ]
        for command in commands {
            guard case .requireWrite = AgentCommandGuard.evaluate(command: command, declaredMode: .read) else {
                return XCTFail("expected write for \(command)")
            }
        }
    }

    func testSafeWrappersStillInspectTheInnerCommand() {
        let commands = [
            "timeout 5 rm -rf /tmp/x",
            "nice rm -rf /tmp/x",
            "nohup rm -rf /tmp/x",
            "command rm -rf /tmp/x",
            "time rm -rf /tmp/x",
            "builtin rm -rf /tmp/x",
            "busybox rm -rf /tmp/x",
            "source ./script.sh",
            ". ./script.sh"
        ]
        for command in commands {
            guard case .requireWrite = AgentCommandGuard.evaluate(command: command, declaredMode: .read) else {
                return XCTFail("expected write for \(command)")
            }
        }
    }

    func testBackgroundCommandsAreInspectedSeparately() {
        let commands = [
            "sleep 1 & rm -rf /tmp/x",
            "docker exec api cat /app/config.yml & rm -rf /tmp/x"
        ]
        for command in commands {
            guard case .requireWrite = AgentCommandGuard.evaluate(command: command, declaredMode: .read) else {
                return XCTFail("expected write for \(command)")
            }
        }
    }

    func testWriteDeclaredAlwaysRequiresGrant() {
        guard case .requireWrite = AgentCommandGuard.evaluate(command: "ls", declaredMode: .write) else {
            return XCTFail("declared write must require grant")
        }
    }
}
