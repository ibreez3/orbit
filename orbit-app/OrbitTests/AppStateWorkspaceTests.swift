import XCTest
@testable import Orbit

final class AppStateWorkspaceTests: XCTestCase {
    func testCurrentServerIdUsesExplicitConnectionTargetNamespace() {
        let state = AppState()
        let local = TabItem(
            id: "local-tab",
            type: .terminal,
            serverId: nil,
            connectionTarget: .local,
            serverName: "Local",
            title: "Local"
        )
        let saved = TabItem(
            id: "saved-tab",
            type: .terminal,
            serverId: "server-1",
            connectionTarget: .saved(serverId: "server-1"),
            serverName: "Saved",
            title: "Saved"
        )
        let temporary = TabItem(
            id: "temporary-tab",
            type: .terminal,
            serverId: nil,
            connectionTarget: .temporary(tabId: "temporary-tab"),
            serverName: "Temporary",
            title: "Temporary"
        )

        XCTAssertEqual(state.currentServerId, "_standalone_")

        state.tabs = [local, saved, temporary]
        state.activeTabId = local.id
        XCTAssertEqual(state.currentServerId, "local")
        XCTAssertNil(state.tabs[0].serverId)

        state.activeTabId = saved.id
        XCTAssertEqual(state.currentServerId, "server-1")

        state.activeTabId = temporary.id
        XCTAssertEqual(state.currentServerId, "temporary:temporary-tab")
        XCTAssertNil(state.tabs[2].serverId)
    }
}
