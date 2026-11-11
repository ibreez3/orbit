import XCTest
@testable import Orbit

final class TerminalResizeDeduperTests: XCTestCase {
    func testIdenticalSizeIsSkippedButNewSizeOrSessionIsSent() {
        var deduper = TerminalResizeDeduplicator()
        XCTAssertTrue(deduper.needsResize(sessionId: "one", cols: 80, rows: 24))
        deduper.record(sessionId: "one", cols: 80, rows: 24)
        XCTAssertFalse(deduper.needsResize(sessionId: "one", cols: 80, rows: 24))
        XCTAssertTrue(deduper.needsResize(sessionId: "one", cols: 81, rows: 24))
        XCTAssertTrue(deduper.needsResize(sessionId: "two", cols: 80, rows: 24))
        deduper.reset()
        XCTAssertTrue(deduper.needsResize(sessionId: "one", cols: 80, rows: 24))
    }

    func testInvalidSizesAndUnrecordedFailures() {
        let deduper = TerminalResizeDeduplicator()
        XCTAssertFalse(deduper.needsResize(sessionId: "one", cols: 0, rows: 24))
        XCTAssertFalse(deduper.needsResize(sessionId: "one", cols: 80, rows: -1))
        XCTAssertTrue(deduper.needsResize(sessionId: "one", cols: 80, rows: 24))
        XCTAssertTrue(deduper.needsResize(sessionId: "one", cols: 80, rows: 24))
    }
}
