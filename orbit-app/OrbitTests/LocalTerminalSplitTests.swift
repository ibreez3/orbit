import XCTest
@testable import Orbit

@MainActor
final class LocalTerminalSplitTests: XCTestCase {
    func testLocalSplitCreatesPaneWithoutSSHChannel() async {
        let bridge = FakeServerWorkspaceBridge()
        let state = AppState(workspaceBridge: bridge)
        state.addLocalTerminalTab()
        guard let tabId = state.tabs.last?.id else {
            return XCTFail("expected a local terminal tab")
        }
        state.updateTabSessionId(tabId, sessionId: "local-session-1")

        state.splitCurrentPane(direction: .vertical)
        try? await Task.sleep(nanoseconds: 150_000_000)

        let tab = state.tabState.tab(id: tabId)
        XCTAssertEqual(tab?.paneTree?.channelIds.count, 2)
        XCTAssertEqual(tab?.paneTree?.channelIds.first, "local-session-1")
        XCTAssertEqual(bridge.spawnCallCount, 0)

        state.closeCurrentPane()
        XCTAssertNil(state.tabState.tab(id: tabId)?.paneTree)
        XCTAssertEqual(state.tabState.tab(id: tabId)?.sessionId, "local-session-1")
        XCTAssertTrue(bridge.disconnectedSessionIds.isEmpty)
        state.cancelAutoReconnects()
    }
}
