import XCTest
@testable import Orbit

@MainActor
final class ServerWorkspaceStateTests: XCTestCase {
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

        try await state.promoteTemporaryTab(tabId: tabId, sessionId: "session-1")

        let tab = state.tabState.tab(id: tabId)
        XCTAssertEqual(tab?.connectionTarget, .saved(serverId: "saved-1"))
        XCTAssertEqual(tab?.serverId, "saved-1")
        XCTAssertEqual(tab?.serverName, "Saved host")
        XCTAssertEqual(tab?.title, "SSH: Saved host")
        XCTAssertEqual(tab?.sessionId, "session-1")
        XCTAssertNil(state.temporaryDraft(for: tabId))
        XCTAssertEqual(bridge.promotedSessionId, "session-1")
        XCTAssertEqual(bridge.promotedInput?.name, "Temporary host")
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
}

private final class FakeServerWorkspaceBridge: ServerWorkspaceBridge {
    private let temporarySessionId: String
    private let promotedServer: Server
    private let promotionError: Error?

    private(set) var connectedInput: TemporaryConnectionInput?
    private(set) var promotedSessionId: String?
    private(set) var promotedInput: PromoteTemporaryServerInput?

    init(
        temporarySessionId: String = "temporary-session",
        promotedServer: Server = .fixture(),
        promotionError: Error? = nil
    ) {
        self.temporarySessionId = temporarySessionId
        self.promotedServer = promotedServer
        self.promotionError = promotionError
    }

    func listServerOrganizationAsync() async throws -> ServerOrganizationSnapshot {
        .init(folders: [], tags: [], tag_links: [])
    }

    func connectTemporarySSHAsync(input: TemporaryConnectionInput) async throws -> String {
        connectedInput = input
        return temporarySessionId
    }

    func promoteTemporaryServerAsync(
        sessionId: String,
        input: PromoteTemporaryServerInput
    ) async throws -> Server {
        promotedSessionId = sessionId
        promotedInput = input
        if let promotionError {
            throw promotionError
        }
        return promotedServer
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
    static func fixture(id: String = "saved-1", name: String = "Saved host") -> Self {
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
            folder_id: "folder-1",
            is_pinned: false,
            pin_order: nil,
            last_connected_at: nil,
            last_attempted_at: nil,
            last_connection_result: nil,
            last_connection_error: nil,
            created_at: "2026-08-07T00:00:00Z",
            updated_at: "2026-08-07T00:00:00Z"
        )
    }
}
