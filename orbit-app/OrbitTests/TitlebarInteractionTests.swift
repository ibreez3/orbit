import AppKit
import XCTest
@testable import Orbit

final class TitlebarInteractionTests: XCTestCase {
    func testDoubleClickPreferenceDefaultsToZoom() {
        XCTAssertEqual(WindowDoubleClickAction.resolve(preference: nil), .zoom)
        XCTAssertEqual(WindowDoubleClickAction.resolve(preference: "Maximize"), .zoom)
        XCTAssertEqual(WindowDoubleClickAction.resolve(preference: "Fill"), .zoom)
        XCTAssertEqual(WindowDoubleClickAction.resolve(preference: "Zoom"), .zoom)
        XCTAssertEqual(WindowDoubleClickAction.resolve(preference: "unknown"), .zoom)
    }

    func testDoubleClickPreferenceHonorsMinimizeAndNone() {
        XCTAssertEqual(WindowDoubleClickAction.resolve(preference: "Minimize"), .minimize)
        XCTAssertEqual(WindowDoubleClickAction.resolve(preference: "None"), .none)
    }

    @MainActor
    func testTitlebarPointIsAboveContentLayoutRect() {
        let window = makeWindow()
        defer { window.close() }

        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titlebarHeight, 0)

        XCTAssertTrue(
            TitlebarInteractionController.isTitlebarPoint(
                NSPoint(x: window.frame.width / 2, y: window.contentLayoutRect.maxY + 1),
                in: window
            )
        )
        XCTAssertFalse(
            TitlebarInteractionController.isTitlebarPoint(
                NSPoint(x: window.frame.width / 2, y: window.contentLayoutRect.maxY - 40),
                in: window
            )
        )
    }

    @MainActor
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
