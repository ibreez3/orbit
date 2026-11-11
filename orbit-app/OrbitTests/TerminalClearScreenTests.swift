import XCTest
@testable import Orbit

@MainActor
final class TerminalClearScreenTests: XCTestCase {
    func testClearRemovesVisibleTextAndHistoryAndHomesCursor() throws {
        let view = OrbitTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.feed(text: (0..<100).map { "line \($0)\r\n" }.joined())
        view.clearScreenAndScrollback()

        XCTAssertTrue(view.contextText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let snapshot = try XCTUnwrap(view.terminalContentSnapshot(region: .all))
        XCTAssertTrue(snapshot.rows.allSatisfy { $0.text.isEmpty })
        view.feed(text: "new")
        XCTAssertTrue(view.contextText().hasPrefix("new"))
    }
}
