import XCTest
@testable import AgentKit

final class AgentShellSentinelTests: XCTestCase {
    func testParsesOutputAndExitCodeAcrossChunks() {
        let sentinel = AgentShellSentinel(uuid: "abc")
        var buffer = "line1\nline2\n"
        XCTAssertNil(sentinel.consume(buffer: &buffer))
        buffer += "__ORBIT_DONE_abc__7\n"
        let result = sentinel.consume(buffer: &buffer)
        XCTAssertEqual(result, AgentShellCommandResult(output: "line1\nline2", exitCode: 7))
        XCTAssertEqual(buffer, "")
    }

    func testMarkerInsideOutputDoesNotCollideWithFullLine() {
        let sentinel = AgentShellSentinel(uuid: "abc")
        var buffer = "prefix __ORBIT_DONE_abc__0 suffix\n__ORBIT_DONE_abc__3\n"
        XCTAssertEqual(sentinel.consume(buffer: &buffer)?.exitCode, 3)
    }
}
