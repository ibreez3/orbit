import XCTest
import SwiftTerm
@testable import Orbit

@MainActor
final class TerminalRenderPlanTests: XCTestCase {
    private func key(theme: AppTheme = .catppuccinMocha, size: CGFloat = 14,
                     blur: Bool = false, cursor: String = "bar", scrollback: Int = 10000) -> TerminalRenderKey {
        TerminalRenderKey(theme: theme, backgroundAlpha: 1, snapshot: TerminalSettingsSnapshot(
            fontFamily: "Menlo", fontSize: size, fontLigatures: false,
            cursorStyle: cursor, scrollbackLines: scrollback, backgroundBlur: blur
        ))
    }

    func testNoOpPreservesInputModesAndSelectionWithoutResizing() {
        let view = OrbitTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let delegate = TerminalTestDelegate()
        view.terminalDelegate = delegate
        view.configureRenderSettings(key())
        view.feed(text: "selected\u{1b}[?1h\u{1b}[?2004h\u{1b}[3;10r")
        view.perform(#selector(NSResponder.selectAll(_:)), with: nil)
        let state = view.terminalInputStateSnapshot()
        delegate.sizes.removeAll()

        view.configureRenderSettings(key())
        view.setFrameSize(view.frame.size)

        XCTAssertEqual(delegate.sizes.count, 0)
        XCTAssertEqual(view.terminalInputStateSnapshot(), state)
        XCTAssertTrue(view.selectionActive)
    }

    func testThemeAndBlurPreserveFontAndModes() {
        let view = OrbitTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let delegate = TerminalTestDelegate()
        view.terminalDelegate = delegate
        view.configureRenderSettings(key())
        let font = view.font
        view.feed(text: "\u{1b}[?1h")
        delegate.sizes.removeAll()
        view.configureRenderSettings(key(theme: .light))
        let foreground = view.nativeForegroundColor
        view.configureRenderSettings(key(theme: .light, blur: true))

        XCTAssertEqual(view.font, font)
        XCTAssertEqual(view.nativeBackgroundColor.alphaComponent, 0.82, accuracy: 0.001)
        XCTAssertEqual(view.nativeForegroundColor, foreground)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.applicationCursor, true)
        XCTAssertTrue(delegate.sizes.isEmpty)
    }

    func testFontChangesOnceAndCursorAndScrollbackDoNotResetIt() {
        let view = OrbitTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let delegate = TerminalTestDelegate()
        view.terminalDelegate = delegate
        view.configureRenderSettings(key())
        delegate.sizes.removeAll()
        view.configureRenderSettings(key(size: 18))
        XCTAssertEqual(view.font.pointSize, 18)
        XCTAssertLessThanOrEqual(delegate.sizes.count, 1)
        view.feed(text: "\u{1b}[?1h")
        delegate.sizes.removeAll()
        view.configureRenderSettings(key(size: 18, cursor: "block"))
        view.configureRenderSettings(key(size: 18, cursor: "block", scrollback: 500))
        XCTAssertTrue(delegate.sizes.isEmpty)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.applicationCursor, true)
    }
}
