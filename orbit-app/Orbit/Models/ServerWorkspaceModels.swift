import Foundation
import Darwin

struct ParsedServerAddress: Equatable {
    let host: String
    let port: UInt16
    let username: String?
}

enum ServerAddressError: Error, Equatable {
    case emptyAddress
    case invalidUsername
    case invalidHost
    case invalidPort
    case ambiguousIPv6
}

enum ServerAddressParser {
    static func parse(_ value: String) -> Result<ParsedServerAddress, ServerAddressError> {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return .failure(.emptyAddress) }

        let userAndEndpoint = address.split(separator: "@", omittingEmptySubsequences: false)
        guard userAndEndpoint.count <= 2 else { return .failure(.invalidUsername) }

        let username: String?
        let endpoint: String
        if userAndEndpoint.count == 2 {
            let candidate = String(userAndEndpoint[0])
            guard isValidUsername(candidate) else { return .failure(.invalidUsername) }
            username = candidate
            endpoint = String(userAndEndpoint[1])
        } else {
            username = nil
            endpoint = String(userAndEndpoint[0])
        }

        guard !endpoint.isEmpty else { return .failure(.invalidHost) }

        if endpoint.hasPrefix("[") {
            guard let closingBracket = endpoint.firstIndex(of: "]") else {
                return .failure(.invalidHost)
            }
            let hostStart = endpoint.index(after: endpoint.startIndex)
            let host = String(endpoint[hostStart..<closingBracket])
            let suffixStart = endpoint.index(after: closingBracket)
            let suffix = String(endpoint[suffixStart...])
            guard isValidIPv6(host) else {
                return .failure(.invalidHost)
            }
            if suffix.isEmpty {
                return .success(.init(host: host, port: 22, username: username))
            }
            guard suffix.hasPrefix(":"), suffix.count > 1 else {
                return .failure(.invalidPort)
            }
            return parsed(host: host, portText: String(suffix.dropFirst()), username: username)
        }

        guard !endpoint.contains("[") && !endpoint.contains("]") else {
            return .failure(.invalidHost)
        }

        let colonCount = endpoint.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colonCount > 1 {
            return .failure(.ambiguousIPv6)
        }
        if colonCount == 1 {
            let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return .failure(.invalidHost) }
            return parsed(
                host: String(parts[0]),
                portText: String(parts[1]),
                username: username
            )
        }

        guard isValidHost(endpoint) else { return .failure(.invalidHost) }
        return .success(.init(host: endpoint, port: 22, username: username))
    }

    private static func parsed(
        host: String,
        portText: String,
        username: String?
    ) -> Result<ParsedServerAddress, ServerAddressError> {
        guard isValidHost(host) else { return .failure(.invalidHost) }
        guard let portValue = Int(portText), (1...65535).contains(portValue) else {
            return .failure(.invalidPort)
        }
        return .success(.init(host: host, port: UInt16(portValue), username: username))
    }

    private static func isValidUsername(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private static func isValidHost(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return value.rangeOfCharacter(from: CharacterSet(charactersIn: "/@?#[]")) == nil
    }

    private static func isValidIPv6(_ value: String) -> Bool {
        var address = in6_addr()
        return value.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address) == 1
        }
    }
}

struct ServerSearchMatch {
    let server: Server
    let folderPath: String?
    let tags: [String]
}

enum ServerSearchResult {
    case saved(ServerSearchMatch)
    case temporary(ParsedServerAddress)
    case newServer(query: String)
}

struct ServerSearchIndex {
    private struct Entry {
        let server: Server
        let folderPath: String?
        let tags: [String]
    }

    private let entries: [Entry]

    init(servers: [Server], organization: ServerOrganizationSnapshot) {
        let foldersById = Dictionary(uniqueKeysWithValues: organization.folders.map { ($0.id, $0) })
        let tagsById = Dictionary(uniqueKeysWithValues: organization.tags.map { ($0.id, $0.name) })
        let tagIdsByServer = Dictionary(grouping: organization.tag_links, by: \.server_id)

        entries = servers.map { server in
            let tags = (tagIdsByServer[server.id] ?? [])
                .compactMap { tagsById[$0.tag_id] }
                .sorted(by: Self.stableTextOrder)
            return Entry(
                server: server,
                folderPath: Self.folderPath(for: server.folder_id, foldersById: foldersById),
                tags: tags
            )
        }
    }

    func search(_ value: String) -> [ServerSearchMatch] {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        return entries.compactMap { entry -> (Int, Entry)? in
            let name = entry.server.name.lowercased()
            let host = entry.server.host.lowercased()
            let rank: Int
            if name == query {
                rank = 0
            } else if name.hasPrefix(query) {
                rank = 1
            } else if host.hasPrefix(query) {
                rank = 2
            } else if name.contains(query)
                        || host.contains(query)
                        || entry.folderPath?.lowercased().contains(query) == true
                        || entry.tags.contains(where: { $0.lowercased().contains(query) }) {
                rank = 3
            } else {
                return nil
            }
            return (rank, entry)
        }
        .sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if Self.stableTextOrder(lhs.1.server.name, rhs.1.server.name) { return true }
            if Self.stableTextOrder(rhs.1.server.name, lhs.1.server.name) { return false }
            return lhs.1.server.id < rhs.1.server.id
        }
        .map { ranked in
            ServerSearchMatch(
                server: ranked.1.server,
                folderPath: ranked.1.folderPath,
                tags: ranked.1.tags
            )
        }
    }

    private static func folderPath(
        for folderId: String?,
        foldersById: [String: ServerFolder]
    ) -> String? {
        guard var currentId = folderId else { return nil }
        var names: [String] = []
        var visited: Set<String> = []
        while let folder = foldersById[currentId], visited.insert(currentId).inserted {
            names.append(folder.name)
            guard let parentId = folder.parent_id else { break }
            currentId = parentId
        }
        return names.isEmpty ? nil : names.reversed().joined(separator: "/")
    }

    private static func stableTextOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.lowercased()
        let right = rhs.lowercased()
        return left == right ? lhs < rhs : left < right
    }
}

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
    var isConnecting = false
    var validationError: String?
    var connectionError: String?

    mutating func clearSecrets() {
        password = ""
        privateKey = ""
        keyPassphrase = ""
    }
}

struct TemporaryPromotionFailure: Equatable {
    let sessionId: String
    var message: String
    var isRetrying = false
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

extension ServerOrganizationSnapshot {
    static let empty = Self(folders: [], tags: [], tag_links: [])
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
