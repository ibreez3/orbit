import XCTest
@testable import Orbit

@MainActor
final class TerminalContextCollectorTests: XCTestCase {
    func testContextPreservesVisibleOrderAndUnicodeWithoutEscapeCodes() {
        let view = OrbitTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.feed(text: "first\r\n\u{1b}[31m中文 café\u{1b}[0m\r\nlast")

        let lines = view.contextText().components(separatedBy: "\n")

        XCTAssertEqual(Array(lines.prefix(3)), ["first", "中文 café", "last"])
        XCTAssertFalse(view.contextText().contains("\u{1b}"))
        XCTAssertFalse(view.contextText().contains("\u{0}"))
    }

    func testContextUsesActiveAlternateScreen() {
        let view = OrbitTerminalView()
        view.feed(text: "shell\u{1b}[?1049h\u{1b}[2J\u{1b}[Hagent")
        XCTAssertTrue(view.contextText().hasPrefix("agent"))
        XCTAssertFalse(view.contextText().contains("shell"))
        view.feed(text: "\u{1b}[?1049l")
        XCTAssertTrue(view.contextText().hasPrefix("shell"))
    }
}
