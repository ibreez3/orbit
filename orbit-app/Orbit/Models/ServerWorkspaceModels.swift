import Foundation

enum ServerConnectionTarget: Equatable {
    case saved(serverId: String)
    case temporary(tabId: String)
    case local
}

struct TemporaryConnectionDraft: Equatable {
    var host: String
    var port: UInt16
    var username: String
    var authType: String
    var password = ""
    var privateKey = ""
    var keySource = "content"
    var keyFilePath = ""
    var keyPassphrase = ""
    var credentialGroupId: String?
    var jumpServerId: String?
    var saveToAssets = false
    var displayName = ""
    var folderId: String?
    var tagIds: [String] = []

    mutating func clearSecrets() {
        password = ""
        privateKey = ""
        keyPassphrase = ""
    }
}

struct ServerFolder: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let normalized_name: String
    let parent_id: String?
    let sort_order: Int64
    let created_at: String
    let updated_at: String
}

struct ServerTag: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let normalized_name: String
    let created_at: String
    let updated_at: String
}

struct ServerTagLink: Codable, Equatable {
    let server_id: String
    let tag_id: String
}

struct ServerOrganizationSnapshot: Codable, Equatable {
    let folders: [ServerFolder]
    let tags: [ServerTag]
    let tag_links: [ServerTagLink]
}

struct FolderInput: Codable, Equatable {
    var name: String
    var parent_id: String?
    var sort_order: Int64?
}

struct FolderMoveInput: Codable, Equatable {
    var parent_id: String?
    var sort_order: Int64
}

struct FolderDeleteInput: Codable, Equatable {
    var destination_folder_id: String?
    var delete_servers: Bool
}

struct ServerTagsInput: Codable, Equatable {
    var tag_ids: [String]
}

struct ServerMoveInput: Codable, Equatable {
    var folder_id: String?
}

struct ServerPinInput: Codable, Equatable {
    var is_pinned: Bool
    var pin_order: Int64?
}

struct TemporaryConnectionInput: Codable, Equatable {
    var host: String
    var port: UInt16
    var username: String
    var auth_type: String
    var password: String?
    var private_key: String?
    var key_source: String?
    var key_file_path: String?
    var key_passphrase: String?
    var credential_group_id: String?
    var jump_server_id: String?
}

struct PromoteTemporaryServerInput: Codable, Equatable {
    var connection: TemporaryConnectionInput
    var name: String
    var folder_id: String?
    var tag_ids: [String]
}

protocol ServerWorkspaceBridge {
    func listServerOrganizationAsync() async throws -> ServerOrganizationSnapshot
    func connectTemporarySSHAsync(input: TemporaryConnectionInput) async throws -> String
    func spawnChannelAsync(existingSessionId: String) async throws -> String
    func disconnectSSHAsync(sessionId: String) async throws
    func promoteTemporaryServerAsync(
        sessionId: String,
        input: PromoteTemporaryServerInput
    ) async throws -> Server
}
