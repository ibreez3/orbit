import XCTest
@testable import Orbit

@MainActor
final class AutoReconnectSettingsTests: XCTestCase {
    private static let draft = TemporaryConnectionDraft(
        host: "127.0.0.1",
        port: 22,
        username: "tester",
        authType: "password",
        password: "secret"
    )

    private let defaults = UserDefaults.standard
    private var hadEnabled = false
    private var previousEnabled: Any?
    private var hadInterval = false
    private var previousInterval: Any?

    override func setUp() {
        super.setUp()
        hadEnabled = defaults.object(forKey: "sshReconnectEnabled") != nil
        previousEnabled = defaults.object(forKey: "sshReconnectEnabled")
        hadInterval = defaults.object(forKey: "sshReconnectInterval") != nil
        previousInterval = defaults.object(forKey: "sshReconnectInterval")
    }

    override func tearDown() {
        if hadEnabled, let previousEnabled {
            defaults.set(previousEnabled, forKey: "sshReconnectEnabled")
        } else {
            defaults.removeObject(forKey: "sshReconnectEnabled")
        }
        if hadInterval, let previousInterval {
            defaults.set(previousInterval, forKey: "sshReconnectInterval")
        } else {
            defaults.removeObject(forKey: "sshReconnectInterval")
        }
        super.tearDown()
    }

    func testReconnectIsEnabledByDefaultAndCanBeDisabled() {
        defaults.removeObject(forKey: "sshReconnectEnabled")
        let state = AppState(workspaceBridge: FakeServerWorkspaceBridge())
        XCTAssertTrue(state.isAutoReconnectEnabled)

        defaults.set(false, forKey: "sshReconnectEnabled")
        XCTAssertFalse(state.isAutoReconnectEnabled)
    }

    func testReconnectIntervalIsClampedToSliderRange() {
        let state = AppState(workspaceBridge: FakeServerWorkspaceBridge())

        defaults.set(0.5, forKey: "sshReconnectInterval")
        XCTAssertEqual(state.autoReconnectInterval, 1)

        defaults.set(90.0, forKey: "sshReconnectInterval")
        XCTAssertEqual(state.autoReconnectInterval, 30)
    }

    func testEnabledSettingReconnectsClosedTerminal() async {
        defaults.set(true, forKey: "sshReconnectEnabled")
        defaults.set(1.0, forKey: "sshReconnectInterval")

        let connectStarted = expectation(description: "auto reconnect started")
        let bridge = FakeServerWorkspaceBridge(connectStarted: connectStarted)
        let state = AppState(workspaceBridge: bridge)
        let tabId = state.addTemporaryTerminalTab(draft: Self.draft, sessionId: "session-1")

        state.handleChannelClosed(channelId: "session-1")
        XCTAssertNil(state.tabState.tab(id: tabId)?.sessionId)

        await fulfillment(of: [connectStarted], timeout: 5)
        bridge.resumeConnect(sessionId: "temporary-session")
        for _ in 0..<40 where state.tabState.tab(id: tabId)?.sessionId == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(state.tabState.tab(id: tabId)?.sessionId, "temporary-session")
        state.cancelAutoReconnects()
    }

    func testDisabledSettingDoesNotReconnectClosedTerminal() async {
        defaults.set(false, forKey: "sshReconnectEnabled")
        defaults.set(1.0, forKey: "sshReconnectInterval")

        let bridge = FakeServerWorkspaceBridge()
        let state = AppState(workspaceBridge: bridge)
        let tabId = state.addTemporaryTerminalTab(draft: Self.draft, sessionId: "session-1")

        state.handleChannelClosed(channelId: "session-1")
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(bridge.connectCallCount, 0)
        XCTAssertNil(state.tabState.tab(id: tabId)?.sessionId)
        state.cancelAutoReconnects()
    }
}
