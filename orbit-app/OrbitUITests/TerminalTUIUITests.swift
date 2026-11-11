import AppKit
import XCTest

final class TerminalTUIUITests: XCTestCase {
    private var app: XCUIApplication!
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tui-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-fontFamily", "Menlo", "-fontSize", "14",
                               "-selectToCopy", "YES", "-terminalUseMetal", "YES", "-keyBindings_json", "{}"]
        app.launchEnvironment["ORBIT_DB_PATH"] = directory.appendingPathComponent("orbit.db").path
        app.launchEnvironment["ORBIT_AGENT_SUPPORT_DIR"] = directory.path
        app.launchEnvironment["ORBIT_DISABLE_UPDATE_CHECKS"] = "1"
        app.launchEnvironment["ORBIT_TERMINAL_DIAGNOSTICS"] = "1"
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func openTerminal(metal: Bool) -> XCUIElement {
        app.launchEnvironment["ORBIT_TERMINAL_METAL"] = metal ? "1" : "0"
        app.launch()
        app.activate()
        let button = app.buttons["homeLocalTerminalButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        let terminal = app.descendants(matching: .any).matching(identifier: "orbitTerminal").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).click()
        app.activate()
        return terminal
    }

    private func diagnostics() throws -> [String: Any] {
        NSPasteboard.general.clearContents()
        app.typeKey("d", modifierFlags: [.command, .option, .shift])
        let ready = NSPredicate { _, _ in
            NSPasteboard.general.string(forType: .string)?.hasPrefix("{") == true
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
        let text = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func startFixture(selection: Bool = false) throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tui-fixture", withExtension: "sh", subdirectory: "Fixtures"))
        let path = fixture.path.replacingOccurrences(of: "'", with: "'\\''")
        runCommand("/bin/bash '\(path)'\(selection ? " --selection" : "")")
    }

    private func runCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        app.typeKey("v", modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
    }

    private func waitForVisibleText(containing needle: String,
                                    timeout: TimeInterval = 5) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try diagnostics()
        while Date() < deadline {
            if (latest["visibleText"] as? String)?.contains(needle) == true {
                return latest
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            latest = try diagnostics()
        }
        return latest
    }

    private func waitForClearedText(timeout: TimeInterval = 5) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try diagnostics()
        while Date() < deadline {
            if (latest["visibleText"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                return latest
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            latest = try diagnostics()
        }
        return latest
    }

    func testTUIOutputUsesMetalAndDoesNotDecorateOrScan() throws {
        _ = openTerminal(metal: true)
        try startFixture()
        var initial = try diagnostics()
        for _ in 0..<10 where initial["isAlternateBuffer"] as? Bool != true {
            initial = try diagnostics()
        }
        XCTAssertEqual(initial["isAlternateBuffer"] as? Bool, true, "\(initial)")
        XCTAssertEqual(initial["mouseMode"] as? String, "vt200")
        XCTAssertEqual(initial["linkHighlightMode"] as? String, "hoverWithModifier")
        XCTAssertEqual(initial["isUsingMetalRenderer"] as? Bool, true)
        XCTAssertEqual(initial["isUsingRenderLoop"] as? Bool, true)
        let later = try diagnostics()
        XCTAssertEqual(later["keywordInjectionCount"] as? Int, initial["keywordInjectionCount"] as? Int)
        XCTAssertEqual(later["errorScanCount"] as? Int, initial["errorScanCount"] as? Int)
        XCTAssertEqual(later["sizeChangedCount"] as? Int, initial["sizeChangedCount"] as? Int)
        XCTAssertTrue((later["visibleText"] as? String)?.contains("ERROR: fixture") == true)
        app.typeKey("c", modifierFlags: .control)
    }

    func testClearScreenAndCoreGraphicsFallback() throws {
        _ = openTerminal(metal: false)
        runCommand("printf 'ORBIT_CLEAR_MARKER\\n'")
        let before = try waitForVisibleText(containing: "ORBIT_CLEAR_MARKER")
        XCTAssertTrue((before["visibleText"] as? String)?.contains("ORBIT_CLEAR_MARKER") == true, "\(before)")
        XCTAssertEqual(before["isUsingMetalRenderer"] as? Bool, false)
        app.typeKey("l", modifierFlags: .command)
        let cleared = try waitForClearedText()
        XCTAssertEqual((cleared["visibleText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testSelectionAndCopySurviveStreamingOutput() throws {
        let terminal = openTerminal(metal: true)
        try startFixture(selection: true)
        let initial = try waitForVisibleText(containing: "ORBIT_SELECTION")
        XCTAssertTrue((initial["visibleText"] as? String)?.contains("ORBIT_SELECTION") == true, "\(initial)")
        XCTAssertTrue(app.dialogs.firstMatch.waitForNonExistence(timeout: 5))
        let origin = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let cellWidth = terminal.frame.width / CGFloat(try XCTUnwrap(initial["cols"] as? Int))
        let cellHeight = terminal.frame.height / CGFloat(try XCTUnwrap(initial["rows"] as? Int))
        let start = origin.withOffset(CGVector(dx: cellWidth * 4, dy: cellHeight * 4.5))
        let end = origin.withOffset(CGVector(dx: cellWidth * 19, dy: cellHeight * 4.5))
        let beforeDrag = NSPasteboard.general.changeCount
        start.click(forDuration: 0.1, thenDragTo: end)
        let afterDrag = NSPasteboard.general.changeCount
        let selected = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertEqual(selected.trimmingCharacters(in: .whitespacesAndNewlines), "ORBIT_SELECTION")
        XCTAssertEqual(afterDrag - beforeDrag, 1, "select-to-copy must write the pasteboard once")
        let count = afterDrag
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), selected)
        XCTAssertEqual(NSPasteboard.general.changeCount - count, 1, "Cmd+C must copy once")
        let state = try diagnostics()
        XCTAssertEqual(state["selectionActive"] as? Bool, true, "initial=\(initial) current=\(state)")
        app.typeKey("c", modifierFlags: .control)
    }
}
