import XCTest
@testable import Orbit

@MainActor
final class ServerWorkspaceStateTests: XCTestCase {
    func testTreeBuildsThreeLevelsAndSearchPreservesPath() {
        let tree = ServerTreeProjection(
            snapshot: .threeLevelFixture(),
            servers: [.fixture(id: "s1", name: "Edge Web", folderId: "leaf")]
        )

        XCTAssertEqual(tree.roots.first?.children.first?.children.first?.depth, 3)
        XCTAssertEqual(tree.path(forServerId: "s1"), "客户 / 生产 / Web")
        XCTAssertEqual(tree.search("web").first?.path, "客户 / 生产 / Web")
        XCTAssertEqual(tree.search("k8s").first?.server.id, "s1")
    }

    func testTreeOnlyShowsNonEmptyDerivedViewsAndFiltersOneTag() {
        let servers = [
            Server.fixture(id: "pinned", isPinned: true),
            Server.fixture(id: "recent", lastAttemptedAt: "2026-08-07T00:00:00Z"),
            Server.fixture(id: "plain", folderId: nil)
        ]
        let snapshot = ServerOrganizationSnapshot(
            folders: [],
            tags: [ServerTag.fixture(id: "prod", name: "生产")],
            tag_links: [.init(server_id: "plain", tag_id: "prod")]
        )
        let tree = ServerTreeProjection(snapshot: snapshot, servers: servers)

        XCTAssertEqual(tree.visibleSystemViews, [.all, .pinned, .recent, .uncategorized])
        XCTAssertEqual(tree.servers(tagged: "prod").map(\.id), ["plain"])
        XCTAssertEqual(
            ServerTreeProjection(snapshot: .empty, servers: []).visibleSystemViews,
            [.all]
        )
    }

    func testRecentSystemViewIncludesLegacyHistoryFallback() {
        let server = Server.fixture(id: "legacy", folderId: nil)
        let tree = ServerTreeProjection(
            snapshot: .empty,
            servers: [server],
            legacyRecentIds: ["legacy"]
        )

        XCTAssertTrue(tree.visibleSystemViews.contains(.recent))
        XCTAssertEqual(tree.servers(for: .recent).map(\.id), ["legacy"])
    }

    func testEqualSortOrderReorderProducesUniqueContinuousOrder() {
        let folders = [
            ServerFolder.fixture(id: "a", name: "A", parentId: nil, sortOrder: 0),
            ServerFolder.fixture(id: "b", name: "B", parentId: nil, sortOrder: 0),
            ServerFolder.fixture(id: "c", name: "C", parentId: nil, sortOrder: 0)
        ]

        let moves = ServerFolderOrdering.reorderedMoves(
            folders: folders,
            movingId: "b",
            direction: -1
        )

        XCTAssertEqual(moves.map(\.folderId), ["b", "a", "c"])
        XCTAssertEqual(moves.map(\.sortOrder), [0, 1, 2])
    }

    func testSelectingAllClearsTagFilterAndExpandsSidebar() {
        let state = AppState(workspaceBridge: FakeServerWorkspaceBridge())
        state.uiState.selectedServerTagId = "prod"
        state.uiState.assetTreeCollapsed = true

        state.selectServerSystemView(.all)

        XCTAssertNil(state.uiState.selectedServerTagId)
        XCTAssertFalse(state.uiState.assetTreeCollapsed)
        XCTAssertEqual(state.uiState.selectedServerSystemView, .all)
    }

    func testFailedNewServerSaveBindsPersistedRecordAndRetryUpdatesWithoutDuplicateAdd() async throws {
        let authoritativeServer = Server.fixture(id: "persisted", folderId: nil)
        let authoritativeSnapshot = ServerOrganizationSnapshot(
            folders: [],
            tags: [ServerTag.fixture(id: "old", name: "旧标签")],
            tag_links: [.init(server_id: "persisted", tag_id: "old")]
        )
        let bridge = FakeServerWorkspaceBridge(
            savedServer: authoritativeServer,
            organization: authoritativeSnapshot,
            setTagErrors: [FakeError.tagReplacementFailed]
        )
        let state = AppState(workspaceBridge: bridge)
        var persistence = ServerDialogPersistence()

        do {
            _ = try await state.saveServer(.fixture(folderId: nil), tagIds: ["new"], editingId: nil)
            XCTFail("Expected tag replacement to fail")
        } catch let failure as ServerSaveFailure {
            persistence.bind(
                serverId: failure.serverId,
                servers: state.servers,
                snapshot: state.serverOrganization
            )
        }

        XCTAssertEqual(bridge.addServerCallCount, 1)
        XCTAssertEqual(bridge.movedServerFolders, [nil])
        XCTAssertEqual(persistence.savedServerId, "persisted")
        XCTAssertEqual(persistence.selectedTagIds, ["old"])

        _ = try await state.saveServer(
            .fixture(folderId: nil),
            tagIds: Array(persistence.selectedTagIds),
            editingId: persistence.targetServerId(fallback: nil)
        )

        XCTAssertEqual(bridge.addServerCallCount, 1)
        XCTAssertEqual(bridge.updateServerCallCount, 1)
        XCTAssertEqual(bridge.movedServerFolders, [nil, nil])
    }

    func testEditingServerToUncategorizedUsesExplicitMoveAndReloadsRecord() async throws {
        let bridge = FakeServerWorkspaceBridge(
            savedServer: .fixture(id: "persisted", folderId: nil)
        )
        let state = AppState(workspaceBridge: bridge)

        let saved = try await state.saveServer(
            .fixture(folderId: nil),
            tagIds: [],
            editingId: "persisted"
        )

        XCTAssertEqual(saved.folder_id, nil)
        XCTAssertEqual(bridge.addServerCallCount, 0)
        XCTAssertEqual(bridge.updateServerCallCount, 1)
        XCTAssertEqual(bridge.movedServerFolders, [nil])
        XCTAssertEqual(state.servers.first?.folder_id, nil)
    }

    func testSnapshotRefreshFailureKeepsSavedIdentityAndRecoversAuthoritativeTags() async {
        let initialOrganizationLoaded = expectation(description: "initial organization loaded")
        let bridge = FakeServerWorkspaceBridge(
            savedServer: .fixture(id: "persisted", folderId: nil),
            organization: .init(
                folders: [],
                tags: [.fixture(id: "new", name: "新标签")],
                tag_links: []
            ),
            initialOrganizationLoaded: initialOrganizationLoaded
        )
        let state = AppState(workspaceBridge: bridge)
        await fulfillment(of: [initialOrganizationLoaded], timeout: 1)
        bridge.failNextOrganizationRefresh()
        var persistence = ServerDialogPersistence()

        do {
            _ = try await state.saveServer(.fixture(folderId: nil), tagIds: ["new"], editingId: nil)
            XCTFail("Expected the post-save snapshot refresh to fail")
        } catch let failure as ServerSaveFailure {
            persistence.bind(
                serverId: failure.serverId,
                servers: state.servers,
                snapshot: state.serverOrganization
            )
        } catch {
            XCTFail("Expected ServerSaveFailure, got \(error)")
        }

        XCTAssertEqual(persistence.savedServerId, "persisted")
        XCTAssertEqual(persistence.selectedTagIds, ["new"])
        XCTAssertEqual(bridge.addServerCallCount, 1)
        XCTAssertEqual(bridge.updateServerCallCount, 0)
    }

    func testFolderDropValidationRejectsCyclesAndDepthOverflow() {
        let tree = ServerTreeProjection(snapshot: .threeLevelFixture(), servers: [])

        XCTAssertFalse(tree.canMoveFolder("root", toParentId: "middle"))
        XCTAssertFalse(tree.canMoveFolder("middle", toParentId: "leaf"))
        XCTAssertFalse(tree.canMoveFolder("root", toParentId: "leaf"))
        XCTAssertTrue(tree.canMoveFolder("leaf", toParentId: nil))
        XCTAssertFalse(tree.canCreateChild(in: "leaf"))
    }

    func testSidebarWidthClampsPersistsAndRestoresCollapse() {
        let suiteName = "ServerWorkspaceStateTests.Sidebar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SidebarPresentation.clampedWidth(120), 180)
        XCTAssertEqual(SidebarPresentation.clampedWidth(420), 360)
        XCTAssertEqual(SidebarPresentation(collapsed: true, width: 240).displayWidth, 48)

        SidebarPresentation(collapsed: true, width: 320).save(to: defaults)
        XCTAssertEqual(SidebarPresentation.restore(from: defaults), .init(collapsed: true, width: 320))
    }

    func testTemporaryTabOwnsDraftUntilClosed() {
        let state = AppState(workspaceBridge: FakeServerWorkspaceBridge())
        let draft = TemporaryConnectionDraft.fixture(password: "secret")

        let tabId = state.addTemporaryTerminalTab(draft: draft)

        XCTAssertEqual(state.temporaryDraft(for: tabId), draft)
        XCTAssertEqual(
            state.tabState.tab(id: tabId)?.connectionTarget,
            .temporary(tabId: tabId)
        )

        state.removeTab(tabId)

        XCTAssertNil(state.tabState.temporaryDrafts[tabId])
    }

    func testTemporaryConnectionDispatchesDraftThroughWorkspaceBridge() async throws {
        let bridge = FakeServerWorkspaceBridge(temporarySessionId: "temporary-session")
        let state = AppState(workspaceBridge: bridge)
        let draft = TemporaryConnectionDraft.fixture(password: "secret")
        let tabId = state.addTemporaryTerminalTab(draft: draft)

        let sessionId = try await state.connectSSH(for: .temporary(tabId: tabId))

        XCTAssertEqual(sessionId, "temporary-session")
        XCTAssertEqual(
            bridge.connectedInput,
            TemporaryConnectionInput(
                host: "10.0.0.1",
                port: 2222,
                username: "alice",
                auth_type: "password",
                password: "secret",
                private_key: nil,
                key_source: nil,
                key_file_path: nil,
                key_passphrase: nil,
                credential_group_id: nil,
                jump_server_id: "jump-1"
            )
        )
    }

    func testCanceledQuickConnectDiscardsBufferedCallbacksAndRejectsDuplicateSubmit() async {
        let connectStarted = expectation(description: "temporary connect started")
        let disconnected = expectation(description: "canceled session disconnected")
        let bridge = FakeServerWorkspaceBridge(
            connectStarted: connectStarted,
            disconnected: disconnected
        )
        let state = AppState(workspaceBridge: bridge)
        state.presentTemporaryConnectionPanel(
            address: .init(host: "10.0.0.1", port: 2222, username: "alice")
        )
        state.uiState.temporaryConnectionDraft?.password = "secret"

        let submission = state.submitTemporaryConnection()
        let duplicate = state.submitTemporaryConnection()
        await fulfillment(of: [connectStarted], timeout: 1)

        let sessionId = "canceled-session"
        OrbitBridge.shared.handleSSHData(
            sessionId: sessionId,
            data: Data("buffered".utf8)
        )
        state.dismissTemporaryConnectionPanel()
        bridge.resumeConnect(sessionId: sessionId)
        await submission?.value
        await fulfillment(of: [disconnected], timeout: 1)

        var received: [Data] = []
        OrbitBridge.shared.setSSHHandlers(
            sessionId: sessionId,
            dataHandler: { received.append($0) },
            closedHandler: {}
        )
        defer { OrbitBridge.shared.removeSSHHandlers(sessionId: sessionId) }

        XCTAssertNil(duplicate)
        XCTAssertEqual(bridge.connectCallCount, 1)
        XCTAssertEqual(bridge.disconnectedSessionIds, [sessionId])
        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(state.tabs.isEmpty)
    }

    func testSavePromotionFailureIsTabScopedAndRetryReusesConnectedSession() async {
        let bridge = FakeServerWorkspaceBridge(
            promotionErrors: [FakeError.promotionFailed]
        )
        let state = AppState(workspaceBridge: bridge)
        state.presentTemporaryConnectionPanel(
            address: .init(host: "10.0.0.1", port: 2222, username: "alice")
        )
        state.uiState.temporaryConnectionDraft?.password = "secret"
        state.uiState.temporaryConnectionDraft?.saveToAssets = true
        state.uiState.temporaryConnectionDraft?.displayName = "Temporary host"

        let submission = state.submitTemporaryConnection()
        await submission?.value

        guard let temporaryTabId = state.tabs.first?.id else {
            return XCTFail("Expected a connected temporary tab")
        }
        let connectedSessionId = state.tabs.first?.sessionId
        state.addLocalTerminalTab()

        let failure = state.temporaryPromotionFailure(for: temporaryTabId)
        XCTAssertEqual(failure?.sessionId, connectedSessionId)
        XCTAssertEqual(failure?.isRetrying, false)
        XCTAssertNil(state.temporaryPromotionFailure(for: state.activeTabId!))
        XCTAssertEqual(
            state.tabState.tab(id: temporaryTabId)?.connectionTarget,
            .temporary(tabId: temporaryTabId)
        )
        XCTAssertEqual(bridge.connectCallCount, 1)
        XCTAssertEqual(bridge.promotionCallCount, 1)

        await state.retryTemporaryPromotion(tabId: temporaryTabId)

        XCTAssertNil(state.temporaryPromotionFailure(for: temporaryTabId))
        XCTAssertEqual(
            state.tabState.tab(id: temporaryTabId)?.connectionTarget,
            .saved(serverId: "saved-1")
        )
        XCTAssertEqual(state.tabState.tab(id: temporaryTabId)?.sessionId, connectedSessionId)
        XCTAssertEqual(bridge.connectCallCount, 1)
        XCTAssertEqual(bridge.promotionCallCount, 2)
    }

    func testSessionReplacementDuringPromotionRetryClearsRetryStateWithoutRepersisting() async {
        let retryStarted = expectation(description: "promotion retry started")
        let bridge = FakeServerWorkspaceBridge(
            promotionErrors: [FakeError.promotionFailed],
            promotionStarted: retryStarted,
            promotionSuspendCall: 2
        )
        let state = AppState(workspaceBridge: bridge)
        state.presentTemporaryConnectionPanel(
            address: .init(host: "10.0.0.1", port: 2222, username: "alice")
        )
        state.uiState.temporaryConnectionDraft?.password = "secret"
        state.uiState.temporaryConnectionDraft?.saveToAssets = true
        state.uiState.temporaryConnectionDraft?.displayName = "Temporary host"

        let submission = state.submitTemporaryConnection()
        await submission?.value

        guard let tabId = state.tabs.first?.id else {
            return XCTFail("Expected a connected temporary tab")
        }
        let retry = Task { await state.retryTemporaryPromotion(tabId: tabId) }
        await fulfillment(of: [retryStarted], timeout: 1)
        state.tabs[0].sessionId = "replacement-session"
        bridge.resumePromotion()
        await retry.value

        XCTAssertNil(state.temporaryPromotionFailure(for: tabId))
        XCTAssertEqual(
            state.tabState.tab(id: tabId)?.connectionTarget,
            .temporary(tabId: tabId)
        )
        XCTAssertEqual(state.tabState.tab(id: tabId)?.sessionId, "replacement-session")
        XCTAssertNotNil(state.temporaryDraft(for: tabId))
        XCTAssertEqual(bridge.promotionCallCount, 2)

        await state.retryTemporaryPromotion(tabId: tabId)

        XCTAssertEqual(bridge.promotionCallCount, 2)
    }

    func testClosingTabWhileTemporaryConnectIsPendingDiscardsCreatedSession() async throws {
        let connectStarted = expectation(description: "temporary connect started")
        let disconnected = expectation(description: "orphan session disconnected")
        let bridge = FakeServerWorkspaceBridge(
            connectStarted: connectStarted,
            disconnected: disconnected
        )
        let state = AppState(workspaceBridge: bridge)
        let tabId = state.addTemporaryTerminalTab(draft: .fixture(password: "secret"))
        let target = ServerConnectionTarget.temporary(tabId: tabId)

        let connectTask = Task { try await state.connectSSH(for: target) }
        await fulfillment(of: [connectStarted], timeout: 1)
        state.removeTab(tabId)
        bridge.resumeConnect(sessionId: "orphan-session")
        let sessionId = try await connectTask.value

        OrbitBridge.shared.handleSSHData(
            sessionId: sessionId,
            data: Data("buffered".utf8)
        )
        let installed = await state.installSSHSession(
            tabId: tabId,
            expectedTarget: target,
            sessionId: sessionId,
            dataHandler: { _ in XCTFail("Orphan data must not drain") },
            closedHandler: { XCTFail("Orphan close must not drain") }
        )

        XCTAssertFalse(installed)
        await fulfillment(of: [disconnected], timeout: 1)
        XCTAssertEqual(bridge.disconnectedSessionIds, ["orphan-session"])
        XCTAssertNil(state.tabState.tab(id: tabId))
    }

    func testFailedPromotionPreservesSessionTargetAndDraft() async {
        let bridge = FakeServerWorkspaceBridge(promotionError: FakeError.promotionFailed)
        let state = AppState(workspaceBridge: bridge)
        let draft = TemporaryConnectionDraft.fixture(password: "secret")
        let tabId = state.addTemporaryTerminalTab(draft: draft)
        state.updateTabSessionId(tabId, sessionId: "session-1")

        do {
            try await state.promoteTemporaryTab(tabId: tabId, sessionId: "session-1")
            XCTFail("Expected promotion to fail")
        } catch {
            XCTAssertEqual(error as? FakeError, .promotionFailed)
        }

        let tab = state.tabState.tab(id: tabId)
        XCTAssertEqual(tab?.connectionTarget, .temporary(tabId: tabId))
        XCTAssertEqual(tab?.sessionId, "session-1")
        XCTAssertEqual(state.temporaryDraft(for: tabId), draft)
    }

    func testSuccessfulPromotionRebindsSameTabAndClearsDraft() async throws {
        let promotedServer = Server.fixture(id: "saved-1", name: "Saved host")
        let bridge = FakeServerWorkspaceBridge(promotedServer: promotedServer)
        let state = AppState(workspaceBridge: bridge)
        let tabId = state.addTemporaryTerminalTab(draft: .fixture(password: "secret"))
        state.updateTabSessionId(tabId, sessionId: "session-1")

        let outcome = try await state.promoteTemporaryTab(tabId: tabId, sessionId: "session-1")

        let tab = state.tabState.tab(id: tabId)
        XCTAssertEqual(outcome, .promoted(serverId: "saved-1"))
        XCTAssertEqual(tab?.connectionTarget, .saved(serverId: "saved-1"))
        XCTAssertEqual(tab?.serverId, "saved-1")
        XCTAssertEqual(tab?.serverName, "Saved host")
        XCTAssertEqual(tab?.title, "SSH: Saved host")
        XCTAssertEqual(tab?.sessionId, "session-1")
        XCTAssertNil(state.temporaryDraft(for: tabId))
        XCTAssertEqual(bridge.promotedSessionId, "session-1")
        XCTAssertEqual(bridge.promotedInput?.name, "Temporary host")
    }

    func testOverlappingPromotionOnlyPersistsOnce() async throws {
        let promotionStarted = expectation(description: "first promotion started")
        let bridge = FakeServerWorkspaceBridge(promotionStarted: promotionStarted)
        let state = AppState(workspaceBridge: bridge)
        let tabId = state.addTemporaryTerminalTab(draft: .fixture(password: "secret"))
        state.updateTabSessionId(tabId, sessionId: "session-1")

        let firstPromotion = Task {
            try await state.promoteTemporaryTab(tabId: tabId, sessionId: "session-1")
        }
        await fulfillment(of: [promotionStarted], timeout: 1)

        do {
            _ = try await state.promoteTemporaryTab(tabId: tabId, sessionId: "session-1")
            XCTFail("Expected overlapping promotion to be rejected")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .promotionInProgress)
        }

        XCTAssertEqual(bridge.promotionCallCount, 1)
        bridge.resumePromotion()
        let firstOutcome = try await firstPromotion.value
        XCTAssertEqual(firstOutcome, .promoted(serverId: "saved-1"))
    }

    func testCloseAndRecreateDuringPromotionDoesNotRebindReplacementTab() async throws {
        let promotionStarted = expectation(description: "promotion started")
        let bridge = FakeServerWorkspaceBridge(promotionStarted: promotionStarted)
        let state = AppState(workspaceBridge: bridge)
        let tabId = state.addTemporaryTerminalTab(draft: .fixture(password: "secret"))
        state.updateTabSessionId(tabId, sessionId: "session-1")

        let promotion = Task {
            try await state.promoteTemporaryTab(tabId: tabId, sessionId: "session-1")
        }
        await fulfillment(of: [promotionStarted], timeout: 1)
        state.removeTab(tabId)
        let replacement = TabItem(
            id: tabId,
            type: .terminal,
            serverId: nil,
            connectionTarget: .temporary(tabId: tabId),
            serverName: "Replacement",
            title: "SSH: Replacement",
            sessionId: "replacement-session"
        )
        state.tabs.append(replacement)
        state.tabState.temporaryDrafts[tabId] = .fixture(password: "replacement-secret")

        bridge.resumePromotion()
        let outcome = try await promotion.value

        XCTAssertEqual(outcome, .persistedAfterTabClosed(serverId: "saved-1"))
        XCTAssertEqual(
            state.tabState.tab(id: tabId)?.connectionTarget,
            .temporary(tabId: tabId)
        )
        XCTAssertEqual(state.tabState.tab(id: tabId)?.sessionId, "replacement-session")
        XCTAssertEqual(state.temporaryDraft(for: tabId)?.password, "replacement-secret")
    }

    func testClosingTabWhileSplitIsPendingDiscardsSpawnedChannel() async {
        let spawnStarted = expectation(description: "spawn started")
        let disconnected = expectation(description: "orphan channel disconnected")
        let bridge = FakeServerWorkspaceBridge(
            spawnStarted: spawnStarted,
            disconnected: disconnected
        )
        let state = AppState(workspaceBridge: bridge)
        let tabId = state.addTemporaryTerminalTab(draft: .fixture())
        state.updateTabSessionId(tabId, sessionId: "source-channel")

        state.splitCurrentPane(direction: .horizontal)
        await fulfillment(of: [spawnStarted], timeout: 1)
        state.removeTab(tabId)
        bridge.resumeSpawn(channelId: "orphan-channel")

        await fulfillment(of: [disconnected], timeout: 1)
        XCTAssertEqual(bridge.disconnectedSessionIds, ["orphan-channel"])
    }

    func testClosingSplitSourceWhileSpawnIsPendingDiscardsSpawnedChannel() async {
        let spawnStarted = expectation(description: "spawn started")
        let disconnected = expectation(description: "orphan channel disconnected")
        let bridge = FakeServerWorkspaceBridge(
            spawnStarted: spawnStarted,
            disconnected: disconnected
        )
        let state = AppState(workspaceBridge: bridge)
        let tabId = state.addTemporaryTerminalTab(draft: .fixture())
        state.updateTabSessionId(tabId, sessionId: "source-channel")
        let otherChannel = "other-channel"
        state.tabs[0].paneTree = .split(
            id: "existing-split",
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(channelId: "source-channel"),
            second: .leaf(channelId: otherChannel)
        )
        state.tabs[0].focusedChannelId = "source-channel"

        state.splitCurrentPane(direction: .vertical)
        await fulfillment(of: [spawnStarted], timeout: 1)
        state.handleChannelClosed(channelId: "source-channel")
        bridge.resumeSpawn(channelId: "orphan-channel")

        await fulfillment(of: [disconnected], timeout: 1)
        XCTAssertEqual(state.tabState.tab(id: tabId)?.sessionId, otherChannel)
        XCTAssertNil(state.tabState.tab(id: tabId)?.paneTree)
        XCTAssertEqual(bridge.disconnectedSessionIds, ["orphan-channel"])
    }

    func testConnectedTemporaryTabAllowsSessionToolsButNotPersistedServerTools() {
        let state = AppState(workspaceBridge: FakeServerWorkspaceBridge())
        let tabId = state.addTemporaryTerminalTab(draft: .fixture())
        state.updateTabSessionId(tabId, sessionId: "session-1")

        XCTAssertNil(state.canOpenTool(.ai))
        XCTAssertNil(state.canOpenTool(.snippets))
        XCTAssertNotNil(state.canOpenTool(.sftp))
        XCTAssertNotNil(state.canOpenTool(.monitor))
        XCTAssertFalse(state.canUsePersistedServerTools)
    }
}

private enum FakeError: Error, Equatable {
    case promotionFailed
    case tagReplacementFailed
    case snapshotRefreshFailed
}

private final class FakeServerWorkspaceBridge: ServerWorkspaceBridge {
    private let temporarySessionId: String
    private let promotedServer: Server
    private var promotionErrors: [Error]
    private let connectStarted: XCTestExpectation?
    private let promotionStarted: XCTestExpectation?
    private let promotionSuspendCall: Int
    private let spawnStarted: XCTestExpectation?
    private let disconnected: XCTestExpectation?

    private var connectContinuation: CheckedContinuation<String, Never>?
    private var promotionContinuation: CheckedContinuation<Server, Never>?
    private var spawnContinuation: CheckedContinuation<String, Never>?

    private(set) var connectedInput: TemporaryConnectionInput?
    private(set) var connectCallCount = 0
    private(set) var promotedSessionId: String?
    private(set) var promotedInput: PromoteTemporaryServerInput?
    private(set) var promotionCallCount = 0
    private(set) var disconnectedSessionIds: [String] = []
    private(set) var addServerCallCount = 0
    private(set) var updateServerCallCount = 0
    private(set) var movedServerFolders: [String?] = []

    private let savedServer: Server
    private var organization: ServerOrganizationSnapshot
    private var setTagErrors: [Error]
    private let initialOrganizationLoaded: XCTestExpectation?
    private var organizationCallCount = 0
    private var failNextOrganization = false

    init(
        temporarySessionId: String = "temporary-session",
        promotedServer: Server = .fixture(),
        promotionError: Error? = nil,
        promotionErrors: [Error] = [],
        connectStarted: XCTestExpectation? = nil,
        promotionStarted: XCTestExpectation? = nil,
        promotionSuspendCall: Int = 1,
        spawnStarted: XCTestExpectation? = nil,
        disconnected: XCTestExpectation? = nil,
        savedServer: Server = .fixture(),
        organization: ServerOrganizationSnapshot = .empty,
        setTagErrors: [Error] = [],
        initialOrganizationLoaded: XCTestExpectation? = nil
    ) {
        self.temporarySessionId = temporarySessionId
        self.promotedServer = promotedServer
        self.promotionErrors = promotionError.map { [$0] } ?? promotionErrors
        self.connectStarted = connectStarted
        self.promotionStarted = promotionStarted
        self.promotionSuspendCall = promotionSuspendCall
        self.spawnStarted = spawnStarted
        self.disconnected = disconnected
        self.savedServer = savedServer
        self.organization = organization
        self.setTagErrors = setTagErrors
        self.initialOrganizationLoaded = initialOrganizationLoaded
    }

    func listServerOrganizationAsync() async throws -> ServerOrganizationSnapshot {
        organizationCallCount += 1
        if organizationCallCount == 1 { initialOrganizationLoaded?.fulfill() }
        if failNextOrganization {
            failNextOrganization = false
            throw FakeError.snapshotRefreshFailed
        }
        return organization
    }

    func listServers() throws -> [Server] { [savedServer] }

    func addServer(input: ServerInput) throws -> Server {
        addServerCallCount += 1
        return savedServer
    }

    func updateServer(id: String, input: ServerInput) throws -> Server {
        updateServerCallCount += 1
        return savedServer
    }

    func moveServerAsync(serverId: String, folderId: String?) async throws {
        movedServerFolders.append(folderId)
    }

    func setServerTagsAsync(serverId: String, tagIds: [String]) async throws {
        if !setTagErrors.isEmpty { throw setTagErrors.removeFirst() }
        organization = .init(
            folders: organization.folders,
            tags: organization.tags,
            tag_links: tagIds.map { .init(server_id: serverId, tag_id: $0) }
        )
    }

    func failNextOrganizationRefresh() {
        failNextOrganization = true
    }

    func createServerFolderAsync(input: FolderInput) async throws -> ServerFolder {
        .fixture(id: "folder", name: input.name, parentId: input.parent_id, sortOrder: input.sort_order ?? 0)
    }

    func renameServerFolderAsync(id: String, input: FolderInput) async throws -> ServerFolder {
        .fixture(id: id, name: input.name, parentId: input.parent_id, sortOrder: input.sort_order ?? 0)
    }

    func moveServerFolderAsync(id: String, input: FolderMoveInput) async throws -> ServerFolder {
        .fixture(id: id, name: id, parentId: input.parent_id, sortOrder: input.sort_order)
    }

    func deleteServerFolderAsync(id: String, input: FolderDeleteInput) async throws {}

    func createServerTagAsync(name: String) async throws -> ServerTag {
        .fixture(id: "tag", name: name)
    }

    func setServerPinAsync(
        serverId: String,
        isPinned: Bool,
        pinOrder: Int64?
    ) async throws -> Server {
        savedServer
    }

    func connectTemporarySSHAsync(input: TemporaryConnectionInput) async throws -> String {
        connectCallCount += 1
        connectedInput = input
        if let connectStarted {
            connectStarted.fulfill()
            return await withCheckedContinuation { continuation in
                connectContinuation = continuation
            }
        }
        return temporarySessionId
    }

    func promoteTemporaryServerAsync(
        sessionId: String,
        input: PromoteTemporaryServerInput
    ) async throws -> Server {
        promotionCallCount += 1
        promotedSessionId = sessionId
        promotedInput = input
        if !promotionErrors.isEmpty {
            throw promotionErrors.removeFirst()
        }
        if let promotionStarted, promotionCallCount == promotionSuspendCall {
            promotionStarted.fulfill()
            return await withCheckedContinuation { continuation in
                promotionContinuation = continuation
            }
        }
        return promotedServer
    }

    func spawnChannelAsync(existingSessionId: String) async throws -> String {
        if let spawnStarted {
            spawnStarted.fulfill()
            return await withCheckedContinuation { continuation in
                spawnContinuation = continuation
            }
        }
        return "spawned-channel"
    }

    func disconnectSSHAsync(sessionId: String) async throws {
        disconnectedSessionIds.append(sessionId)
        disconnected?.fulfill()
    }

    func resumeConnect(sessionId: String) {
        connectContinuation?.resume(returning: sessionId)
        connectContinuation = nil
    }

    func resumePromotion() {
        promotionContinuation?.resume(returning: promotedServer)
        promotionContinuation = nil
    }

    func resumeSpawn(channelId: String) {
        spawnContinuation?.resume(returning: channelId)
        spawnContinuation = nil
    }
}

private extension TemporaryConnectionDraft {
    static func fixture(password: String = "") -> Self {
        .init(
            host: "10.0.0.1",
            port: 2222,
            username: "alice",
            authType: "password",
            password: password,
            jumpServerId: "jump-1",
            saveToAssets: true,
            displayName: "Temporary host",
            folderId: "folder-1",
            tagIds: ["tag-1"]
        )
    }
}

private extension Server {
    static func fixture(
        id: String = "saved-1",
        name: String = "Saved host",
        folderId: String? = "folder-1",
        isPinned: Bool = false,
        lastAttemptedAt: String? = nil
    ) -> Self {
        .init(
            id: id,
            name: name,
            host: "10.0.0.1",
            port: 2222,
            group_name: "",
            auth_type: "password",
            username: "alice",
            password: "",
            private_key: "",
            key_source: "content",
            key_file_path: "",
            key_passphrase: "",
            credential_group_id: "",
            jump_server_id: "jump-1",
            folder_id: folderId,
            is_pinned: isPinned,
            pin_order: nil,
            last_connected_at: nil,
            last_attempted_at: lastAttemptedAt,
            last_connection_result: nil,
            last_connection_error: nil,
            created_at: "2026-08-07T00:00:00Z",
            updated_at: "2026-08-07T00:00:00Z"
        )
    }
}

private extension ServerOrganizationSnapshot {
    static func threeLevelFixture() -> Self {
        .init(
            folders: [
                .fixture(id: "root", name: "客户", parentId: nil, sortOrder: 0),
                .fixture(id: "middle", name: "生产", parentId: "root", sortOrder: 0),
                .fixture(id: "leaf", name: "Web", parentId: "middle", sortOrder: 0)
            ],
            tags: [.fixture(id: "k8s", name: "K8S")],
            tag_links: [.init(server_id: "s1", tag_id: "k8s")]
        )
    }
}

private extension ServerFolder {
    static func fixture(
        id: String,
        name: String,
        parentId: String?,
        sortOrder: Int64
    ) -> Self {
        .init(
            id: id,
            name: name,
            normalized_name: name.lowercased(),
            parent_id: parentId,
            sort_order: sortOrder,
            created_at: "2026-08-07T00:00:00Z",
            updated_at: "2026-08-07T00:00:00Z"
        )
    }
}

private extension ServerTag {
    static func fixture(id: String, name: String) -> Self {
        .init(
            id: id,
            name: name,
            normalized_name: name.lowercased(),
            created_at: "2026-08-07T00:00:00Z",
            updated_at: "2026-08-07T00:00:00Z"
        )
    }
}

private extension ServerInput {
    static func fixture(folderId: String?) -> Self {
        .init(
            name: "Saved host",
            host: "10.0.0.1",
            port: 22,
            group_name: nil,
            auth_type: "password",
            username: "alice",
            password: "secret",
            private_key: nil,
            key_source: "content",
            key_file_path: nil,
            key_passphrase: nil,
            credential_group_id: nil,
            jump_server_id: nil,
            folder_id: folderId
        )
    }
}
