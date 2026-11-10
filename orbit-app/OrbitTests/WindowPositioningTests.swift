import XCTest
import AppKit
@testable import Orbit

final class WindowPositioningTests: XCTestCase {
    func testCentersWindowOnAnchor() {
        let origin = NSWindowPositioning.centeredOrigin(
            windowSize: NSSize(width: 400, height: 300),
            anchorFrame: NSRect(x: 100, y: 100, width: 800, height: 600),
            visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        XCTAssertEqual(origin.x, 300, accuracy: 0.5)
        XCTAssertEqual(origin.y, 250, accuracy: 0.5)
    }

    func testClampsWindowToVisibleFrame() {
        let origin = NSWindowPositioning.centeredOrigin(
            windowSize: NSSize(width: 400, height: 300),
            anchorFrame: NSRect(x: 0, y: 0, width: 100, height: 100),
            visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertEqual(origin.x, 0)
        XCTAssertEqual(origin.y, 0)
    }
}
