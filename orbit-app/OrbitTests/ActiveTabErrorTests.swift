import XCTest
@testable import Orbit

final class ActiveTabErrorTests: XCTestCase {
    private func state() -> AppState {
        let state = AppState()
        state.tabs = [TabItem(id: "tab", type: .terminal, serverId: nil, connectionTarget: .local,
                             serverName: "Local", title: "Local", sessionId: "one", focusedChannelId: "two")]
        state.activeTabId = "tab"
        return state
    }

    func testOnlyActiveTabAndFocusedPaneCanPublishError() {
        let state = state()
        XCTAssertNil(state.setActiveTabError("background pane", tabId: "tab", sessionId: "one"))
        XCTAssertNil(state.setActiveTabError("background tab", tabId: "other", sessionId: "two"))
        XCTAssertNil(state.tabState.activeTabError)
        XCTAssertNotNil(state.setActiveTabError("focused", tabId: "tab", sessionId: "two"))
        XCTAssertEqual(state.tabState.visibleActiveTabError?.message, "focused")
    }

    func testOldDismissCannotClearNewIdenticalError() throws {
        let state = state()
        let old = try XCTUnwrap(state.setActiveTabError("same", tabId: "tab", sessionId: "two"))
        let current = try XCTUnwrap(state.setActiveTabError("same", tabId: "tab", sessionId: "two"))
        state.clearActiveTabError(matchingGeneration: old)
        XCTAssertEqual(state.tabState.activeTabError?.generation, current)
        state.clearActiveTabError(matchingGeneration: current)
        XCTAssertNil(state.tabState.activeTabError)
    }

    func testTabAndPaneSwitchHideForeignErrors() {
        let state = state()
        state.setActiveTabError("error", tabId: "tab", sessionId: "two")
        state.activeTabId = "other"
        XCTAssertNil(state.tabState.visibleActiveTabError)
        state.activeTabId = "tab"
        XCTAssertNotNil(state.tabState.visibleActiveTabError)
        state.tabs[0].focusedChannelId = "one"
        XCTAssertNil(state.tabState.visibleActiveTabError)
    }
}
