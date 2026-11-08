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

    @MainActor
    func testInstallingSessionPublishesOwnershipBeforeDrainingEarlyClose() async {
        let bridge = OrbitBridge.shared
        let state = AppState()
        let sessionId = "test-early-close-owner-\(UUID().uuidString)"
        let tab = TabItem(
            id: "saved-tab",
            type: .terminal,
            serverId: "server-1",
            connectionTarget: .saved(serverId: "server-1"),
            serverName: "Saved",
            title: "Saved"
        )
        var lateDeliveryCount = 0
        defer { bridge.removeSSHHandlers(sessionId: sessionId) }

        state.tabs = [tab]
        state.activeTabId = tab.id
        bridge.handleSSHClosed(sessionId: sessionId)

        await state.installSSHSession(
            tabId: tab.id,
            expectedTarget: tab.connectionTarget,
            sessionId: sessionId,
            dataHandler: { _ in },
            closedHandler: { state.handleChannelClosed(channelId: sessionId) }
        )

        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertNil(state.activeTabId)

        bridge.handleSSHData(sessionId: sessionId, data: Data("late".utf8))
        bridge.setSSHHandlers(
            sessionId: sessionId,
            dataHandler: { _ in lateDeliveryCount += 1 },
            closedHandler: {}
        )
        XCTAssertEqual(lateDeliveryCount, 0)
    }
}
