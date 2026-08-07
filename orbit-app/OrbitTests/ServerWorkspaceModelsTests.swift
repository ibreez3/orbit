import XCTest
@testable import Orbit

final class ServerWorkspaceModelsTests: XCTestCase {
    func testServerDecodesOrganizationAndConnectionFields() throws {
        let server = try JSONDecoder().decode(Server.self, from: Data(serverJSON.utf8))

        XCTAssertEqual(server.folder_id, "folder-1")
        XCTAssertTrue(server.is_pinned)
        XCTAssertEqual(server.last_connection_result, "failed")
    }

    func testOrganizationSnapshotDecodesTagLinks() throws {
        let snapshot = try JSONDecoder().decode(
            ServerOrganizationSnapshot.self,
            from: Data(snapshotJSON.utf8)
        )

        XCTAssertEqual(snapshot.tag_links, [.init(server_id: "s1", tag_id: "tag-1")])
    }

    func testTemporaryDraftClearsSecrets() {
        var draft = TemporaryConnectionDraft.fixture(
            password: "secret",
            privateKey: "key",
            passphrase: "phrase"
        )

        draft.clearSecrets()

        XCTAssertEqual(draft.password, "")
        XCTAssertEqual(draft.privateKey, "")
        XCTAssertEqual(draft.keyPassphrase, "")
    }

    func testTabItemStoresPersistedIdOnlyForSavedTargets() {
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
        let local = TabItem(
            id: "local-tab",
            type: .terminal,
            serverId: nil,
            connectionTarget: .local,
            serverName: "Local",
            title: "Local"
        )

        XCTAssertEqual(saved.serverId, "server-1")
        XCTAssertNil(temporary.serverId)
        XCTAssertNil(local.serverId)
    }

    func testTemporaryConnectionInputEncodesRustSnakeCaseFields() throws {
        let input = TemporaryConnectionInput(
            host: "10.0.0.1",
            port: 22,
            username: "root",
            auth_type: "key",
            password: nil,
            private_key: "private-key",
            key_source: "content",
            key_file_path: nil,
            key_passphrase: "passphrase",
            credential_group_id: nil,
            jump_server_id: "jump-1"
        )

        let data = try JSONEncoder().encode(input)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["auth_type"] as? String, "key")
        XCTAssertEqual(json["private_key"] as? String, "private-key")
        XCTAssertEqual(json["jump_server_id"] as? String, "jump-1")
        XCTAssertNil(json["authType"])
    }

    func testXCTestDatabasePathIsPIDScopedOutsideApplicationSupport() {
        let applicationSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support")
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp")

        let url = OrbitBridge.databaseURL(
            applicationSupportDirectory: applicationSupport,
            temporaryDirectory: temporaryDirectory,
            environment: ["XCTestConfigurationFilePath": "/private/tmp/test.xctestconfiguration"],
            processIdentifier: 4321
        )

        XCTAssertEqual(url.path, "/private/tmp/orbit-tests-4321/orbit.db")
        XCTAssertFalse(url.path.hasPrefix(applicationSupport.path))
    }

    func testProductionDatabasePathRemainsInApplicationSupport() {
        let applicationSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support")

        let url = OrbitBridge.databaseURL(
            applicationSupportDirectory: applicationSupport,
            temporaryDirectory: URL(fileURLWithPath: "/private/tmp"),
            environment: [:],
            processIdentifier: 4321
        )

        XCTAssertEqual(
            url.path,
            "/Users/example/Library/Application Support/orbit/orbit.db"
        )
    }

    private let serverJSON = #"""
    {
      "id": "s1",
      "name": "Production",
      "host": "10.0.0.1",
      "port": 22,
      "group_name": "Linux",
      "auth_type": "password",
      "username": "root",
      "password": "",
      "private_key": "",
      "key_source": "content",
      "key_file_path": "",
      "key_passphrase": "",
      "credential_group_id": "",
      "jump_server_id": "",
      "folder_id": "folder-1",
      "is_pinned": true,
      "pin_order": 10,
      "last_connected_at": "2026-08-07T00:00:00Z",
      "last_attempted_at": "2026-08-07T00:01:00Z",
      "last_connection_result": "failed",
      "last_connection_error": "timeout",
      "created_at": "2026-08-01T00:00:00Z",
      "updated_at": "2026-08-07T00:01:00Z"
    }
    """#

    private let snapshotJSON = #"""
    {
      "folders": [
        {
          "id": "folder-1",
          "name": "Production",
          "normalized_name": "production",
          "parent_id": null,
          "sort_order": 0,
          "created_at": "2026-08-01T00:00:00Z",
          "updated_at": "2026-08-01T00:00:00Z"
        }
      ],
      "tags": [
        {
          "id": "tag-1",
          "name": "Critical",
          "normalized_name": "critical",
          "created_at": "2026-08-01T00:00:00Z",
          "updated_at": "2026-08-01T00:00:00Z"
        }
      ],
      "tag_links": [
        { "server_id": "s1", "tag_id": "tag-1" }
      ]
    }
    """#
}

private extension TemporaryConnectionDraft {
    static func fixture(
        password: String,
        privateKey: String,
        passphrase: String
    ) -> Self {
        .init(
            host: "10.0.0.1",
            port: 22,
            username: "root",
            authType: "key",
            password: password,
            privateKey: privateKey,
            keyPassphrase: passphrase
        )
    }
}
