import XCTest
@testable import Orbit

@MainActor
final class TerminalIMETests: XCTestCase {
    func testPreeditDoesNotSendAndCommitSendsUTF8InBothBuffers() {
        for alternate in [false, true] {
            let view = OrbitTerminalView()
            let delegate = TerminalTestDelegate()
            view.terminalDelegate = delegate
            if alternate { view.feed(text: "\u{1b}[?1049h") }
            for text in ["拼音", "かな", "한글", "tiếng Việt"] {
                delegate.sent.removeAll()
                view.setMarkedText(text as NSString, selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertTrue(view.hasMarkedText())
                XCTAssertTrue(delegate.sent.isEmpty)
                view.insertText(text as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertEqual(delegate.sent, Data(text.utf8))
                XCTAssertFalse(view.hasMarkedText())
            }
        }
    }

    func testDeletingPreeditDoesNotSendTerminalBackspace() {
        let view = OrbitTerminalView()
        let delegate = TerminalTestDelegate()
        view.terminalDelegate = delegate
        view.setMarkedText("ni" as NSString, selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("n" as NSString, selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(delegate.sent.isEmpty)
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertTrue(delegate.sent.isEmpty)
    }
}
