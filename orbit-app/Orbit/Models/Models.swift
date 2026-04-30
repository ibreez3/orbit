import Foundation

struct Server: Codable, Identifiable {
    let id: String
    let name: String
    let host: String
    let port: UInt16
    let group_name: String
    let auth_type: String
    let username: String
    let password: String
    let private_key: String
    let key_source: String
    let key_file_path: String
    let key_passphrase: String
    let credential_group_id: String
    let jump_server_id: String
    let created_at: String
    let updated_at: String

    var displayName: String { name }
    var isJumpConfigured: Bool { !jump_server_id.isEmpty }
}

struct ServerInput: Codable {
    var name: String
    var host: String
    var port: UInt16?
    var group_name: String?
    var auth_type: String?
    var username: String
    var password: String?
    var private_key: String?
    var key_source: String?
    var key_file_path: String?
    var key_passphrase: String?
    var credential_group_id: String?
    var jump_server_id: String?
}

struct CredentialGroup: Codable, Identifiable {
    let id: String
    let name: String
    let auth_type: String
    let username: String
    let password: String
    let private_key: String
    let key_source: String
    let key_file_path: String
    let key_passphrase: String
    let created_at: String
    let updated_at: String
}

struct CredentialGroupInput: Codable {
    var name: String
    var auth_type: String?
    var username: String
    var password: String?
    var private_key: String?
    var key_source: String?
    var key_file_path: String?
    var key_passphrase: String?
}

struct ServerStats: Codable {
    let cpu_usage: Double
    let mem_total_mb: UInt64
    let mem_used_mb: UInt64
    let mem_percent: Double
    let disk_total: String
    let disk_used: String
    let disk_percent: Double
    let uptime: String
    let load_avg: String
}

struct FileEntry: Codable, Identifiable {
    var name: String
    var path: String
    let is_dir: Bool
    var size: UInt64
    var modified: String
    var permissions: String

    var id: String { path }
}

enum TabType: String, CaseIterable {
    case terminal
    case sftp
    case monitor
    case database
    case settings
}

enum AppTheme: String, CaseIterable {
    case light
    case dark
    case catppuccinMocha
}

enum SpotlightSection: String, CaseIterable {
    case servers
    case databases
    case credentials
    case actions
}

struct TabItem: Identifiable {
    let id: String
    let type: TabType
    let serverId: String
    let serverName: String
    var title: String
    var sessionId: String?
    var paneTree: PaneNode?
    var focusedChannelId: String?
}

enum SplitDirection: String, Codable {
    case horizontal
    case vertical
}

indirect enum PaneNode: Identifiable {
    case leaf(channelId: String)
    case split(id: String, direction: SplitDirection, ratio: Double, first: PaneNode, second: PaneNode)

    var id: String {
        switch self {
        case .leaf(let channelId):
            return channelId
        case .split(let id, _, _, _, _):
            return id
        }
    }

    var channelIds: [String] {
        switch self {
        case .leaf(let channelId):
            return [channelId]
        case .split(_, _, _, let first, let second):
            return first.channelIds + second.channelIds
        }
    }

    func contains(_ channelId: String) -> Bool {
        channelIds.contains(channelId)
    }

    func findAdjacent(channelId: String, forward: Bool) -> String? {
        let ids = channelIds
        guard let idx = ids.firstIndex(of: channelId) else { return nil }
        let next = forward ? idx + 1 : idx - 1
        guard next >= 0, next < ids.count else { return nil }
        return ids[next]
    }

    func replacingLeaf(channelId: String, with node: PaneNode) -> PaneNode {
        switch self {
        case .leaf(let cid):
            return cid == channelId ? node : self
        case .split(let sid, let dir, let ratio, let first, let second):
            return .split(id: sid, direction: dir, ratio: ratio,
                          first: first.replacingLeaf(channelId: channelId, with: node),
                          second: second.replacingLeaf(channelId: channelId, with: node))
        }
    }

    func updateRatio(splitId: String, newRatio: Double) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let sid, let dir, let ratio, let first, let second):
            if sid == splitId {
                return .split(id: sid, direction: dir, ratio: newRatio, first: first, second: second)
            }
            return .split(id: sid, direction: dir, ratio: ratio,
                          first: first.updateRatio(splitId: splitId, newRatio: newRatio),
                          second: second.updateRatio(splitId: splitId, newRatio: newRatio))
        }
    }

    func removing(channelId: String) -> PaneNode? {
        switch self {
        case .leaf(let cid):
            return cid == channelId ? nil : self
        case .split(_, let dir, let ratio, let first, let second):
            let newFirst = first.removing(channelId: channelId)
            let newSecond = second.removing(channelId: channelId)
            if let f = newFirst, let s = newSecond {
                return .split(id: id, direction: dir, ratio: ratio, first: f, second: s)
            }
            return newFirst ?? newSecond
        }
    }

    func adjusting(channelId: String, delta: Double) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let sid, let dir, let ratio, let first, let second):
            if first.contains(channelId) && second.contains(channelId) {
                let newRatio = max(0.1, min(0.9, ratio + delta))
                return .split(id: sid, direction: dir, ratio: newRatio, first: first, second: second)
            }
            if first.contains(channelId) {
                return .split(id: sid, direction: dir, ratio: ratio,
                              first: first.adjusting(channelId: channelId, delta: delta),
                              second: second)
            }
            if second.contains(channelId) {
                return .split(id: sid, direction: dir, ratio: ratio,
                              first: first,
                              second: second.adjusting(channelId: channelId, delta: delta))
            }
            return self
        }
    }
}

struct HistoryPoint: Identifiable {
    let id = UUID()
    let time: String
    let cpu: Double
    let mem: Double
}

func formatSize(_ bytes: UInt64) -> String {
    if bytes == 0 { return "-" }
    let units = ["B", "KB", "MB", "GB"]
    var i = 0
    var size = Double(bytes)
    while size >= 1024 && i < units.count - 1 {
        size /= 1024
        i += 1
    }
    return String(format: "%.1f %@", size, units[i])
}

extension Server {
    static let placeholder = Server(
        id: "", name: "", host: "", port: 0, group_name: "",
        auth_type: "", username: "", password: "", private_key: "",
        key_source: "", key_file_path: "", key_passphrase: "",
        credential_group_id: "", jump_server_id: "",
        created_at: "", updated_at: ""
    )
}
