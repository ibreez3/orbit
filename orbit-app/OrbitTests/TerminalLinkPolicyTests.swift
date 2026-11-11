import XCTest
import SwiftTerm
@testable import Orbit

@MainActor
final class TerminalLinkPolicyTests: XCTestCase {
    func testTUIRequiresModifierAndRepeatedModePreservesSelection() {
        let view = OrbitTerminalView()
        view.configureRenderSettings(theme: .catppuccinMocha)
        XCTAssertEqual(view.linkHighlightMode, .hover)
        view.setTUIInteractionActive(true)
        XCTAssertEqual(view.linkHighlightMode, .hoverWithModifier)
        view.feed(text: "selected")
        view.perform(#selector(NSResponder.selectAll(_:)), with: nil)
        view.setTUIInteractionActive(true)
        XCTAssertTrue(view.selectionActive)
        view.configureRenderSettings(theme: .light)
        XCTAssertEqual(view.linkHighlightMode, .hoverWithModifier)
        view.setTUIInteractionActive(false)
        XCTAssertEqual(view.linkHighlightMode, .hover)
    }

    func testLatestFontChangeIsAppliedOnlyAfterTUIExits() {
        let view = OrbitTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let delegate = TerminalTestDelegate()
        view.terminalDelegate = delegate
        func configure(_ size: CGFloat, theme: AppTheme = .catppuccinMocha) {
            view.configureRenderSettings(TerminalRenderKey(theme: theme, backgroundAlpha: 1,
                snapshot: TerminalSettingsSnapshot(fontFamily: "Menlo", fontSize: size,
                    fontLigatures: false, cursorStyle: "bar", scrollbackLines: 10000, backgroundBlur: false)))
        }
        configure(14)
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1h")
        view.setTUIInteractionActive(true)
        delegate.sizes.removeAll()
        configure(18)
        configure(20, theme: .light)
        XCTAssertEqual(view.font.pointSize, 14)
        XCTAssertTrue(delegate.sizes.isEmpty)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.applicationCursor, true)
        XCTAssertNotNil(view.toolTip)
        let colorsBefore = view.terminalContentSnapshot(region: .viewport)
        view.feed(text: "\u{1b}[?1049l")
        view.setTUIInteractionActive(false)
        let colorsAfter = view.terminalContentSnapshot(region: .viewport)
        XCTAssertEqual(colorsAfter?.foregroundColor, colorsBefore?.foregroundColor)
        XCTAssertEqual(colorsAfter?.backgroundColor, colorsBefore?.backgroundColor)
        XCTAssertEqual(view.font.pointSize, 20)
        XCTAssertLessThanOrEqual(delegate.sizes.count, 1)
        XCTAssertNil(view.toolTip)
        delegate.sizes.removeAll()
        view.setTUIInteractionActive(false)
        configure(20, theme: .light)
        XCTAssertTrue(delegate.sizes.isEmpty)
    }
}
