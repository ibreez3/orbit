import AppKit
import XCTest

final class OrbitUITests: XCTestCase {
    private var app: XCUIApplication!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orbit-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["ORBIT_DB_PATH"] = temporaryDirectory
            .appendingPathComponent("orbit.db")
            .path
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["homeLocalTerminalButton"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testHomepageAndCommandPalette() {
        XCTAssertTrue(app.buttons["homeLocalTerminalButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["homeAddServerButton"].exists)
        XCTAssertTrue(app.buttons["homeCommandPaletteButton"].exists)

        app.typeKey("p", modifierFlags: [.command, .shift])

        let palette = app.textFields["commandPaletteSearchField"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(palette.waitForExistence(timeout: 2))
    }

    func testDoubleClickTitlebarTogglesZoom() {
        let window = app.windows["Orbit"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let initialFrame = window.frame

        doubleClickTitlebar(of: window)
        let resized = NSPredicate { _, _ in
            abs(window.frame.width - initialFrame.width) > 1
                || abs(window.frame.height - initialFrame.height) > 1
        }
        expectation(for: resized, evaluatedWith: window)
        waitForExpectations(timeout: 5)

        doubleClickTitlebar(of: window)
        let restored = NSPredicate { _, _ in
            abs(window.frame.width - initialFrame.width) <= 1
                && abs(window.frame.height - initialFrame.height) <= 1
        }
        expectation(for: restored, evaluatedWith: window)
        waitForExpectations(timeout: 5)
    }

    func testLocalTerminalSplitCreatesTwoPanes() {
        app.buttons["homeLocalTerminalButton"].click()

        let summary = app.staticTexts["statusBarSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let single = NSPredicate(format: "value CONTAINS %@", "已连接 1 个会话")
        expectation(for: single, evaluatedWith: summary)
        waitForExpectations(timeout: 10)

        app.typeKey("d", modifierFlags: [.command, .shift])

        let split = NSPredicate(format: "value CONTAINS %@", "已连接 2 个会话")
        expectation(for: split, evaluatedWith: summary)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["分屏失败"].exists)
    }

    func testSettingsWindowSupportsZoom() {
        let settings = openSettingsWindow()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        defer {
            if settings.exists {
                app.typeKey("w", modifierFlags: .command)
            }
        }

        let initialFrame = settings.frame
        doubleClickTitlebar(of: settings)
        let resized = NSPredicate { _, _ in
            abs(settings.frame.width - initialFrame.width) > 1
                || abs(settings.frame.height - initialFrame.height) > 1
        }
        expectation(for: resized, evaluatedWith: settings)
        waitForExpectations(timeout: 5)
    }

    func testTemporaryPanelRequiresPasswordAndEscapeClosesIt() {
        let passwordField = openTemporaryPanel(address: "tester@127.0.0.1:1")

        app.buttons["temporaryConnectButton"].click()

        let error = app.staticTexts["temporaryConnectionError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(textValue(error).contains("请输入密码"), textValue(error))

        escapeTemporaryPanel(passwordField)
        XCTAssertTrue(app.textFields["serverQuickConnectInput"].waitForExistence(timeout: 5))
    }

    func testConnectionRefusedShowsErrorAndKeepsAppUsable() {
        openTemporaryPanel(address: "testuser@127.0.0.1:1", password: "invalid")

        let error = app.staticTexts["temporaryConnectionError"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        let message = textValue(error)
        XCTAssertTrue(message.contains("连接失败"), message)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["serverQuickConnectInput"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["homeLocalTerminalButton"].exists)
    }

    func testEditedKeybindingTakesEffect() {
        let settings = openSettingsWindow()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))

        defer {
            if app.textFields["commandPaletteSearchField"].exists {
                app.typeKey(.escape, modifierFlags: [])
            }
            if !settings.exists {
                _ = openSettingsWindow()
            }
            if settings.buttons["快捷键"].waitForExistence(timeout: 3) {
                settings.buttons["快捷键"].click()
            }
            let reset = app.buttons["keybindingResetButton"]
            if reset.waitForExistence(timeout: 3) {
                reset.click()
            }
            if settings.buttons["外观"].exists {
                settings.buttons["外观"].click()
            }
            if settings.exists {
                app.typeKey("w", modifierFlags: .command)
            }
        }

        let shortcutsTab = settings.buttons["快捷键"]
        XCTAssertTrue(shortcutsTab.waitForExistence(timeout: 5))
        shortcutsTab.click()

        let row = app.buttons["keybinding-commandPalette"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowInfo = "rowHittable=\(row.isHittable) rowFrame=\(row.frame) settingsFrame=\(settings.frame)"
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        let recording = app.staticTexts["keybindingRecordingStatus"]
        let overlayAppeared = recording.waitForExistence(timeout: 2)
        XCTAssertTrue(overlayAppeared, "clicking a keybinding row should start recording; \(rowInfo)")
        app.typeKey("j", modifierFlags: .command)
        sleep(1)
        let updatedRow = app.buttons["keybinding-commandPalette"]
        XCTAssertTrue(updatedRow.waitForExistence(timeout: 2))
        let updatedInfo = "overlay=\(overlayAppeared) label=\(updatedRow.label) title=\(updatedRow.title) value=\(String(describing: updatedRow.value))"

        // Leave the capture pane before using a menu shortcut to close.
        if settings.buttons["外观"].exists {
            settings.buttons["外观"].click()
        }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))

        app.typeKey("j", modifierFlags: .command)
        XCTAssertTrue(
            app.textFields["commandPaletteSearchField"].waitForExistence(timeout: 5),
            "the newly recorded shortcut should open the command palette; \(rowInfo); \(updatedInfo)"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    func testRealServerTemporaryConnectionAndReconnect() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ORBIT_TEST_HOST"], !host.isEmpty,
              let user = environment["ORBIT_TEST_USER"], !user.isEmpty,
              let password = environment["ORBIT_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("ORBIT_TEST_HOST/USER/PASSWORD are not set")
        }

        openTemporaryPanel(address: "\(user)@\(host):22", password: password)

        let summary = app.staticTexts["statusBarSummary"]
        let connected = NSPredicate(format: "value CONTAINS %@", "已连接")
        expectation(for: connected, evaluatedWith: summary)
        waitForExpectations(timeout: 30)
        XCTAssertTrue(textValue(summary).contains("已连接"), textValue(summary))

        app.typeKey("r", modifierFlags: [.command, .shift])
        sleep(3)
        XCTAssertTrue(textValue(summary).contains("已连接"), textValue(summary))
    }

    func testRealServerSFTPAndMonitor() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ORBIT_TEST_HOST"], !host.isEmpty,
              let user = environment["ORBIT_TEST_USER"], !user.isEmpty,
              let password = environment["ORBIT_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("ORBIT_TEST_HOST/USER/PASSWORD are not set")
        }

        connectAndPromote(address: "\(user)@\(host):22", password: password, name: "UI Real Server")

        app.typeKey("f", modifierFlags: [.command, .shift])
        let sftpTitle = app.staticTexts["sftpOverlayTitle"]
        XCTAssertTrue(sftpTitle.waitForExistence(timeout: 15))
        sleep(2)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sftpTitle.waitForNonExistence(timeout: 3))

        let monitorButton = app.buttons["dock-monitor"]
        XCTAssertTrue(monitorButton.waitForExistence(timeout: 5))
        XCTAssertTrue(monitorButton.isEnabled)
        monitorButton.click()

        let monitorTitle = app.staticTexts["monitorOverlayTitle"]
        XCTAssertTrue(monitorTitle.waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(monitorTitle.waitForNonExistence(timeout: 3))
    }

    private func connectAndPromote(address: String, password: String, name: String) {
        let passwordField = openTemporaryPanel(address: address)
        paste(password, into: passwordField)

        let toggle = app.descendants(matching: .any)["saveToAssetsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()

        let nameField = app.textFields["temporaryDisplayNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        paste(name, into: nameField)

        let connect = app.buttons["temporaryConnectButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.click()

        let summary = app.staticTexts["statusBarSummary"]
        let connected = NSPredicate(format: "value CONTAINS %@", "已连接")
        expectation(for: connected, evaluatedWith: summary)
        waitForExpectations(timeout: 30)
        sleep(2)
    }

    @discardableResult
    private func openSettingsWindow() -> XCUIElement {
        let settings = app.windows["设置"]
        if !settings.exists {
            let button = app.buttons["dock-settings"]
            if button.waitForExistence(timeout: 5) {
                button.click()
            }
        }
        _ = settings.waitForExistence(timeout: 10)
        return settings
    }

    @discardableResult
    private func doubleClickTitlebar(of window: XCUIElement) {
        let point = window
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 12))
        point.doubleClick()
    }

    private func openTemporaryPanel(address: String) -> XCUIElement {
        let input = app.textFields["serverQuickConnectInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))

        let passwordField = app.secureTextFields["temporaryPasswordField"]
        for _ in 0..<2 {
            paste(address, into: input)
            sleep(1)
            app.typeKey(.return, modifierFlags: [])
            if passwordField.waitForExistence(timeout: 5) {
                break
            }
            app.typeKey(.escape, modifierFlags: [])
            sleep(1)
        }
        XCTAssertTrue(passwordField.exists)
        return passwordField
    }

    private func openTemporaryPanel(address: String, password: String) {
        let passwordField = openTemporaryPanel(address: address)
        paste(password, into: passwordField)

        let connect = app.buttons["temporaryConnectButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.click()
    }

    private func escapeTemporaryPanel(_ passwordField: XCUIElement) {
        for _ in 0..<2 where passwordField.exists {
            app.typeKey(.escape, modifierFlags: [])
            usleep(300_000)
        }
        XCTAssertTrue(passwordField.waitForNonExistence(timeout: 3))
    }

    private func textValue(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }


    private func paste(_ text: String, into element: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        element.click()
        usleep(150_000)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        usleep(200_000)
    }
}
