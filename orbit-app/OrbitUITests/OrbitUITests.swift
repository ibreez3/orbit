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
