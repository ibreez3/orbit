import XCTest
@testable import Orbit

final class TerminalSettingsTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var hadValue = false
    private var previousValue: Any?

    override func setUp() {
        super.setUp()
        hadValue = defaults.object(forKey: "selectToCopy") != nil
        previousValue = defaults.object(forKey: "selectToCopy")
    }

    override func tearDown() {
        if hadValue, let previousValue {
            defaults.set(previousValue, forKey: "selectToCopy")
        } else {
            defaults.removeObject(forKey: "selectToCopy")
        }
        super.tearDown()
    }

    func testSelectToCopyDefaultsToEnabledLikeTheSettingsUI() {
        defaults.removeObject(forKey: "selectToCopy")
        XCTAssertTrue(TerminalRenderSettings.selectToCopyEnabled)

        defaults.set(false, forKey: "selectToCopy")
        XCTAssertFalse(TerminalRenderSettings.selectToCopyEnabled)

        defaults.set(true, forKey: "selectToCopy")
        XCTAssertTrue(TerminalRenderSettings.selectToCopyEnabled)
    }
}
