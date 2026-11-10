import AppKit
import XCTest

final class OrbitUITests: XCTestCase {
    private var app: XCUIApplication!
    private var temporaryDirectory: URL!
    private var agentSupportDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orbit-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        // Unix socket paths are limited to ~104 bytes; the sandboxed UI test
        // runner's container path is already long, so keep this directory short.
        agentSupportDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("a-\(UUID().uuidString.prefix(6))", isDirectory: true)
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["ORBIT_DB_PATH"] = temporaryDirectory
            .appendingPathComponent("orbit.db")
            .path
        app.launchEnvironment["ORBIT_AGENT_SUPPORT_DIR"] = agentSupportDirectory.path
        app.launchEnvironment["ORBIT_DISABLE_UPDATE_CHECKS"] = "1"
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["homeLocalTerminalButton"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        if let agentSupportDirectory {
            try? FileManager.default.removeItem(at: agentSupportDirectory)
        }
    }

    func testAboutWindowShowsVersionAndStatus() {
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        let mainFrame = mainWindow.frame

        let appMenu = app.menuBars.menuBarItems["Orbit"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
        appMenu.click()

        let aboutItem = app.menuItems["关于 Orbit"]
        XCTAssertTrue(aboutItem.waitForExistence(timeout: 5))
        aboutItem.click()

        let about = app.windows["关于 Orbit"]
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        XCTAssertEqual(about.frame.midX, mainFrame.midX, accuracy: 40)
        XCTAssertEqual(about.frame.midY, mainFrame.midY, accuracy: 40)
        XCTAssertLessThan(about.frame.height, 420)

        let version = app.staticTexts["aboutVersionLabel"]
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue(textValue(version).contains("版本"))

        let status = app.staticTexts["aboutUpdateStatusLabel"]
        XCTAssertTrue(status.exists)
        XCTAssertEqual(textValue(status), "更新检查已在测试模式下禁用")

        let toggle = app.switches["aboutAutoCheckToggle"]
        XCTAssertTrue(toggle.exists)
        XCTAssertFalse(toggle.isEnabled)

        let check = app.buttons["aboutCheckForUpdatesButton"]
        XCTAssertTrue(check.exists)
        XCTAssertFalse(check.isEnabled)
        XCTAssertTrue(app.staticTexts["aboutLastCheckLabel"].exists)

        app.typeKey("w", modifierFlags: [.command])
        XCTAssertFalse(about.waitForExistence(timeout: 2))
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

    func testAgentSettingsExposeGatewayControls() {
        let settings = openSettingsWindow()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))

        let tab = settings.buttons["AI Agent"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        XCTAssertTrue(app.switches["agentGatewayEnabledToggle"].waitForExistence(timeout: 5))
    }

    func testAgentSettingsShowGatewayStatus() {
        let settings = openSettingsWindow()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))

        let tab = settings.buttons["AI Agent"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()

        let status = app.staticTexts["agentGatewayStatusLabel"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let toggle = app.switches["agentGatewayEnabledToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        let initialStatus = textValue(status)
        let initialToggle = String(describing: toggle.value)
        if initialStatus != "运行中" {
            toggle.click()
            if !waitForValue(status, "运行中", timeout: 5) {
                let error = app.staticTexts["agentGatewayError"]
                return XCTFail(
                    "initialStatus=\(initialStatus) initialToggle=\(initialToggle) "
                        + "now=\(textValue(status)) toggle=\(String(describing: toggle.value)) "
                        + "error=\(error.exists ? textValue(error) : "none")"
                )
            }
        }
        XCTAssertEqual(textValue(status), "运行中")

        let socket = app.staticTexts["agentGatewaySocketPath"]
        XCTAssertTrue(socket.exists)
        XCTAssertTrue(textValue(socket).hasSuffix("/agent.sock"), textValue(socket))
        XCTAssertTrue(app.staticTexts["agentGatewayLastActivity"].exists)

        toggle.click()
        XCTAssertTrue(waitForValue(status, "已停止", timeout: 5), textValue(status))

        toggle.click()
        XCTAssertTrue(waitForValue(status, "运行中", timeout: 5), textValue(status))
    }

    private func waitForValue(
        _ element: XCUIElement,
        _ value: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, textValue(element) == value {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    func testAgentWriteApproval() throws {
        let cli = try orbitCLIURL()
        let socketDeadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: agentSocketURL.path),
              Date() < socketDeadline {
            usleep(100_000)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: agentSocketURL.path),
            "agent socket did not appear at \(agentSocketURL.path)"
        )

        // Seed a server the agent can target. It does not need to be reachable:
        // this test proves admission and write approval are gated, and that a
        // command result comes back after the approval is granted.
        app.buttons["homeAddServerButton"].click()
        let name = app.textFields["serverNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        paste("UI Write Test", into: name)
        paste("127.0.0.1", into: app.textFields["serverHostField"])
        paste("tester", into: app.textFields["serverUsernameField"])
        let save = app.buttons["serverSaveButton"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        save.click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))

        let auth = try launchCLI(cli, ["auth", "--client", "UI Write Test"])
        defer { terminateIfRunning(auth.process) }
        let allow = app.buttons["agentApprovalAllowButton"]
        XCTAssertTrue(
            allow.waitForExistence(timeout: 10),
            "the admission approval panel should appear before a session is issued"
        )
        allow.click()
        XCTAssertTrue(waitForExit(auth.process, timeout: 15))
        let authOutput = readCLIOutput(auth.pipe)
        let sessionId = try XCTUnwrap(
            authOutput.split(separator: "\n").compactMap { line -> String? in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return object["sessionId"] as? String
            }.first,
            authOutput
        )

        var output = ""
        for _ in 0..<2 {
            let exec = try launchCLI(cli, [
                "exec",
                "--session", sessionId,
                "--server", "UI Write Test",
                "--mode", "write",
                "--", "echo", "write-ok"
            ])
            if allow.waitForExistence(timeout: 10) {
                allow.click()
            }
            XCTAssertTrue(waitForExit(exec.process, timeout: 20))
            output = readCLIOutput(exec.pipe)
            if !output.contains("pending_approval") {
                break
            }
        }
        XCTAssertFalse(output.contains("pending_approval"), output)
        XCTAssertTrue(output.contains("\"status\""), output)
    }

    func testAddServerDialogLayoutAndValidation() {
        app.buttons["homeAddServerButton"].click()

        let name = app.textFields["serverNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["serverHostField"].exists)
        XCTAssertTrue(app.textFields["serverUsernameField"].exists)
        XCTAssertTrue(app.secureTextFields["serverPasswordField"].exists)
        XCTAssertTrue(app.buttons["serverTestButton"].exists)
        XCTAssertTrue(app.buttons["serverCancelButton"].exists)

        let save = app.buttons["serverSaveButton"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled)

        paste("Dialog Test", into: name)
        paste("192.168.1.10", into: app.textFields["serverHostField"])
        paste("tester", into: app.textFields["serverUsernameField"])

        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 5)

        app.buttons["serverCancelButton"].click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
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
        app.activate()
        usleep(200_000)
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

        app.activate()
        usleep(200_000)
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
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    private var agentSocketURL: URL {
        agentSupportDirectory.appendingPathComponent("agent.sock")
    }

    private func orbitCLIURL() throws -> URL {
        var directory = Bundle.main.bundleURL
        for _ in 0..<6 {
            let candidate = directory
                .appendingPathComponent("Orbit.app/Contents/MacOS/orbit-cli")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.orbit.terminal"
        }), let executable = running.executableURL {
            let candidate = executable.deletingLastPathComponent()
                .appendingPathComponent("orbit-cli")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw NSError(domain: "OrbitUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "orbit-cli was not found in the built Orbit.app"
        ])
    }

    private func launchCLI(_ executable: URL, _ arguments: [String]) throws -> (process: Process, pipe: Pipe) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ORBIT_AGENT_SUPPORT_DIR"] = agentSupportDirectory.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return (process, pipe)
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        return !process.isRunning
    }

    private func terminateIfRunning(_ process: Process) {
        if process.isRunning {
            process.terminate()
            _ = waitForExit(process, timeout: 3)
        }
    }

    private func readCLIOutput(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
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
