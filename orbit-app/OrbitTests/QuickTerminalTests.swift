import XCTest
import SwiftTerm
@testable import Orbit

@MainActor
final class QuickTerminalTests: XCTestCase {
    func testTerminalViewIsConfiguredWithInputDelegate() {
        let controller = QuickTerminalController()
        let view = OrbitTerminalView()

        controller.configureTerminalView(view)

        XCTAssertNotNil(view.terminalDelegate)
    }
}
