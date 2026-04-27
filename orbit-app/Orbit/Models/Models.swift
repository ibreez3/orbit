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

struct FileEntryStat: Codable {
    let path: String
    let size: UInt64
    let modified: String
    let permissions: String
}

enum TabType: String, CaseIterable {
    case terminal
    case sftp
    case monitor
}

struct TabItem: Identifiable {
    let id: String
    let type: TabType
    let serverId: String
    let serverName: String
    let title: String
    var sessionId: String?
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
