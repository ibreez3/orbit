import Foundation

struct ServerTreeSearchResult: Identifiable {
    let server: Server
    let path: String?
    let tags: [ServerTag]

    var id: String { server.id }
}

struct ServerFolderNode: Identifiable {
    let folder: ServerFolder
    let depth: Int
    let path: String
    let servers: [Server]
    let children: [ServerFolderNode]

    var id: String { folder.id }
}

struct ServerTreeProjection {
    let roots: [ServerFolderNode]
    let visibleSystemViews: [ServerSystemView]
    let tags: [ServerTag]

    private let servers: [Server]
    private let foldersById: [String: ServerFolder]
    private let tagIdsByServer: [String: Set<String>]
    private let tagsById: [String: ServerTag]
    private let legacyRecentOrder: [String: Int]

    init(
        snapshot: ServerOrganizationSnapshot,
        servers: [Server],
        legacyRecentIds: [String] = []
    ) {
        self.servers = servers
        let legacyOrder = Dictionary(
            legacyRecentIds.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: min
        )
        legacyRecentOrder = legacyOrder
        foldersById = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        tagsById = Dictionary(uniqueKeysWithValues: snapshot.tags.map { ($0.id, $0) })
        tagIdsByServer = Dictionary(grouping: snapshot.tag_links, by: \.server_id)
            .mapValues { Set($0.map(\.tag_id)) }
        tags = snapshot.tags.sorted(by: Self.tagOrder)

        let foldersByParent = Dictionary(grouping: snapshot.folders, by: \.parent_id)
        let serversByFolder = Dictionary(grouping: servers.compactMap { server in
            server.folder_id.map { ($0, server) }
        }, by: \.0).mapValues { $0.map(\.1) }

        func build(_ folder: ServerFolder, depth: Int, parentPath: String?) -> ServerFolderNode {
            let path = [parentPath, folder.name].compactMap { $0 }.joined(separator: " / ")
            let children = depth < 3
                ? (foldersByParent[folder.id] ?? [])
                    .sorted(by: Self.folderOrder)
                    .map { build($0, depth: depth + 1, parentPath: path) }
                : []
            return ServerFolderNode(
                folder: folder,
                depth: depth,
                path: path,
                servers: (serversByFolder[folder.id] ?? []).sorted(by: Self.serverOrder),
                children: children
            )
        }

        roots = (foldersByParent[nil] ?? [])
            .sorted(by: Self.folderOrder)
            .map { build($0, depth: 1, parentPath: nil) }

        var systemViews: [ServerSystemView] = [.all]
        if servers.contains(where: \.is_pinned) { systemViews.append(.pinned) }
        if servers.contains(where: { $0.last_attempted_at != nil || legacyOrder[$0.id] != nil }) {
            systemViews.append(.recent)
        }
        if servers.contains(where: { $0.folder_id == nil }) { systemViews.append(.uncategorized) }
        visibleSystemViews = systemViews
    }

    func path(forServerId serverId: String) -> String? {
        guard let folderId = servers.first(where: { $0.id == serverId })?.folder_id else {
            return nil
        }
        return path(forFolderId: folderId)
    }

    func path(forFolderId folderId: String) -> String? {
        guard var folder = foldersById[folderId] else { return nil }
        var names = [folder.name]
        var visited: Set<String> = [folder.id]
        while let parentId = folder.parent_id,
              let parent = foldersById[parentId],
              visited.insert(parent.id).inserted {
            names.append(parent.name)
            folder = parent
        }
        return names.reversed().joined(separator: " / ")
    }

    func servers(for view: ServerSystemView) -> [Server] {
        switch view {
        case .all:
            return servers.sorted(by: Self.serverOrder)
        case .pinned:
            return servers.filter(\.is_pinned).sorted {
                let lhs = $0.pin_order ?? Int64.max
                let rhs = $1.pin_order ?? Int64.max
                return lhs == rhs ? Self.serverOrder($0, $1) : lhs < rhs
            }
        case .recent:
            return servers.filter { $0.last_attempted_at != nil || legacyRecentOrder[$0.id] != nil }.sorted {
                if $0.last_attempted_at != $1.last_attempted_at {
                    return ($0.last_attempted_at ?? "") > ($1.last_attempted_at ?? "")
                }
                return (legacyRecentOrder[$0.id] ?? Int.max) < (legacyRecentOrder[$1.id] ?? Int.max)
            }
        case .uncategorized:
            return servers.filter { $0.folder_id == nil }.sorted(by: Self.serverOrder)
        }
    }

    func servers(tagged tagId: String) -> [Server] {
        servers.filter { tagIdsByServer[$0.id]?.contains(tagId) == true }
            .sorted(by: Self.serverOrder)
    }

    func tags(forServerId serverId: String) -> [ServerTag] {
        (tagIdsByServer[serverId] ?? [])
            .compactMap { tagsById[$0] }
            .sorted(by: Self.tagOrder)
    }

    func search(_ value: String) -> [ServerTreeSearchResult] {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return servers.compactMap { server in
            let path = path(forServerId: server.id)
            let tags = tags(forServerId: server.id)
            guard server.name.lowercased().contains(query)
                    || server.host.lowercased().contains(query)
                    || path?.lowercased().contains(query) == true
                    || tags.contains(where: { $0.name.lowercased().contains(query) }) else {
                return nil
            }
            return ServerTreeSearchResult(server: server, path: path, tags: tags)
        }
        .sorted { Self.serverOrder($0.server, $1.server) }
    }

    func canCreateChild(in folderId: String) -> Bool {
        depth(of: folderId) < 3
    }

    func canMoveServer(toFolderId folderId: String?) -> Bool {
        guard let folderId else { return true }
        return foldersById[folderId] != nil && depth(of: folderId) <= 3
    }

    func canMoveFolder(_ folderId: String, toParentId parentId: String?) -> Bool {
        guard foldersById[folderId] != nil else { return false }
        if parentId == folderId { return false }
        if let parentId {
            guard foldersById[parentId] != nil else { return false }
            if descendants(of: folderId).contains(parentId) { return false }
        }
        let resultingDepth = (parentId.map(depth(of:)) ?? 0) + subtreeDepth(of: folderId)
        return resultingDepth <= 3
    }

    private func depth(of folderId: String) -> Int {
        guard var folder = foldersById[folderId] else { return Int.max }
        var result = 1
        var visited: Set<String> = [folder.id]
        while let parentId = folder.parent_id,
              let parent = foldersById[parentId],
              visited.insert(parent.id).inserted {
            result += 1
            folder = parent
        }
        return result
    }

    private func descendants(of folderId: String) -> Set<String> {
        var result: Set<String> = []
        var pending = [folderId]
        while let current = pending.popLast() {
            for child in foldersById.values where child.parent_id == current {
                if result.insert(child.id).inserted { pending.append(child.id) }
            }
        }
        return result
    }

    private func subtreeDepth(of folderId: String) -> Int {
        let children = foldersById.values.filter { $0.parent_id == folderId }
        guard !children.isEmpty else { return 1 }
        return 1 + (children.map { subtreeDepth(of: $0.id) }.max() ?? 0)
    }

    private static func folderOrder(_ lhs: ServerFolder, _ rhs: ServerFolder) -> Bool {
        if lhs.sort_order != rhs.sort_order { return lhs.sort_order < rhs.sort_order }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func serverOrder(_ lhs: Server, _ rhs: Server) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }

    private static func tagOrder(_ lhs: ServerTag, _ rhs: ServerTag) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

final class InventoryState: ObservableObject {
    @Published var servers: [Server] = []
    @Published var credentialGroups: [CredentialGroup] = []
    @Published var databaseConnections: [DatabaseConnection] = []
    @Published var databaseBackupRecords: [DatabaseBackupRecord] = []
    @Published var portForwardRules: [PortForwardRule] = []

    @Published var editingServer: Server?
    @Published var dialogDefaults: ServerInput?
    @Published var editingCg: CredentialGroup?
    @Published var editingDatabaseConnection: DatabaseConnection?
    @Published var databaseOperationLoading: Bool = false

    let bridge: any ServerWorkspaceBridge

    init(bridge: any ServerWorkspaceBridge = OrbitBridge.shared) {
        self.bridge = bridge
    }
}
