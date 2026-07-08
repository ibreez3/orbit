import Foundation
import SwiftUI

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
    let net_rx_kbps: Double?
    let net_tx_kbps: Double?
    let net_rx_bytes: UInt64?
    let net_tx_bytes: UInt64?
    let net_interface: String?
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
    case docker
}

struct DockerContainer: Codable, Identifiable {
    let id: String
    let name: String
    let image: String
    let command: String
    let status: String
    let state: String
    let ports: String
    let created: String
    let running_for: String
    let size: String

    var shortId: String { String(id.prefix(12)) }
    var isRunning: Bool { state.lowercased() == "running" || status.lowercased().hasPrefix("up") }
}

struct DockerContainerStats: Codable, Identifiable {
    let id: String
    let name: String
    let cpu_percent: String
    let memory_usage: String
    let memory_percent: String
    let network_io: String
    let block_io: String
    let pids: String
}

struct DockerPanelSnapshot {
    var containers: [DockerContainer] = []
    var statsById: [String: DockerContainerStats] = [:]
    var selectedContainerId: String?
    var logs: String = ""
    var query: String = ""
    var logQuery: String = ""
    var error: String?
    var lastUpdated: Date?
}

// MARK: - Database

struct DatabaseConnection: Codable, Identifiable {
    let id: String
    let name: String
    let group_name: String
    let engine: String
    let ssh_server_id: String
    let use_ssh_tunnel: Bool
    let host: String
    let port: UInt16
    let database_name: String
    let username: String
    let password: String
    let sqlite_path: String
    let ssl_mode: String
    let created_at: String
    let updated_at: String
}

struct DatabaseConnectionInput: Codable {
    var name: String
    var group_name: String?
    var engine: String
    var ssh_server_id: String?
    var use_ssh_tunnel: Bool?
    var host: String?
    var port: UInt16?
    var database_name: String?
    var username: String?
    var password: String?
    var sqlite_path: String?
    var ssl_mode: String?
}

struct DatabaseSchema: Codable {
    let connection_id: String
    let engine: String
    let tables: [DatabaseTableSchema]
}

struct DatabaseTableSchema: Codable, Identifiable {
    let name: String
    let columns: [DatabaseColumnSchema]

    var id: String { name }
}

struct DatabaseColumnSchema: Codable, Identifiable {
    let name: String
    let db_type: String
    let nullable: Bool
    let primary_key: Bool
    let default_value: String?

    var id: String { name }
}

struct DatabaseQueryRequest: Codable {
    var sql: String
    var read_only: Bool
    var timeout_ms: UInt32
}

struct DatabaseQueryResult: Codable {
    let columns: [String]
    let rows: [[String?]]
    let affected_rows: UInt64
    let elapsed_ms: UInt64
    let message: String
}

struct DatabaseBackupRecord: Codable, Identifiable {
    let id: String
    let connection_id: String
    let connection_name: String
    let engine: String
    let artifact_path: String
    let operation: String
    let status: String
    let summary: String
    let created_at: String
}

struct DatabaseOperationResult: Codable {
    let ok: Bool
    let code: String
    let message: String
    let artifact_path: String?
    let affected_rows: UInt64?
}

struct DatabaseRestoreRequest: Codable {
    var backup_path: String
    var target_connection_id: String
    var mode: String
}

struct DatabaseImportPlan: Codable {
    var backup_path: String
    var target_connection_id: String
    var mode: String
    var tables: [DatabaseImportTablePlan]
}

struct DatabaseImportTablePlan: Codable, Identifiable {
    var source_table: String
    var target_table: String
    var columns: [DatabaseImportColumnMapping]

    var id: String { source_table }
}

struct DatabaseImportColumnMapping: Codable, Identifiable {
    var source_column: String
    var target_column: String?
    var target_type: String
    var required_without_default: Bool

    var id: String { source_column }
}

struct DatabaseImportRequest: Codable {
    var plan: DatabaseImportPlan
}

struct DatabasePanelSnapshot {
    var schema: DatabaseSchema?
    var selectedTable: String?
    var sqlText: String = ""
    var queryResult: DatabaseQueryResult?
    var error: String?
    var lastUpdated: Date?
}

enum AppTheme: String, CaseIterable {
    case light
    case dark
    case catppuccinMocha
    case dracula
    case tokyoNight
    case nord
    case solarizedDark
    case gruvboxDark
}

struct ThemeColors {
    let background: (red: CGFloat, green: CGFloat, blue: CGFloat)
    let foreground: (red: CGFloat, green: CGFloat, blue: CGFloat)
    let windowBg: (red: CGFloat, green: CGFloat, blue: CGFloat)
    let cursor: (red: CGFloat, green: CGFloat, blue: CGFloat)
    let ansi: [(red: UInt16, green: UInt16, blue: UInt16)]

    static func colors(for theme: AppTheme) -> ThemeColors {
        // Try loading from ThemeManager (supports file-based themes)
        if let orbitTheme = ThemeManager.shared.theme(withId: theme.rawValue) {
            return orbitTheme.colors
        }
        // Fallback: match built-in themes
        let builtIn = OrbitTheme.allBuiltIn
        if let match = builtIn.first(where: { $0.id == theme.rawValue }) {
            return match.colors
        }
        return OrbitTheme.builtInCatppuccinMocha.colors
    }
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
    var serverName: String
    var title: String
    var sessionId: String?
    var paneTree: PaneNode?
    var focusedChannelId: String?
    var initialCommand: String?
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

// MARK: - Command Snippets

struct CommandSnippet: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var command: String
    var description: String
    var tags: [String]
    var serverId: String?
    var createdAt: Date
    var updatedAt: Date

    static func == (lhs: CommandSnippet, rhs: CommandSnippet) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Port Forwarding

struct PortForwardRule: Codable, Identifiable, Equatable {
    let id: String
    let serverId: String
    let localPort: UInt16
    let remoteHost: String
    let remotePort: UInt16
    var enabled: Bool

    var description: String {
        "127.0.0.1:\(localPort) → \(remoteHost):\(remotePort)"
    }

    static func == (lhs: PortForwardRule, rhs: PortForwardRule) -> Bool {
        lhs.id == rhs.id
    }
}

struct CommandSnippetInput: Codable {
    var name: String
    var command: String
    var description: String
    var tags: [String]
    var serverId: String?
}

// MARK: - Keyword Highlighting

struct KeywordHighlight: Codable, Identifiable, Equatable {
    let id: String
    var pattern: String
    var colorHex: String
    var enabled: Bool

    static func == (lhs: KeywordHighlight, rhs: KeywordHighlight) -> Bool {
        lhs.id == rhs.id
    }

    static let defaults: [KeywordHighlight] = [
        KeywordHighlight(id: "err", pattern: "ERROR", colorHex: "#FF4444", enabled: true),
        KeywordHighlight(id: "warn", pattern: "WARN(ING)?", colorHex: "#FFAA00", enabled: true),
        KeywordHighlight(id: "fail", pattern: "fail(ed|ure)?", colorHex: "#FF6644", enabled: true),
        KeywordHighlight(id: "success", pattern: "success(ful(ly)?)?", colorHex: "#44DD44", enabled: true),
        KeywordHighlight(id: "fatal", pattern: "FATAL", colorHex: "#FF0044", enabled: true),
        KeywordHighlight(id: "panic", pattern: "panic", colorHex: "#FF0044", enabled: true),
    ]
}

// MARK: - AI Configuration

struct AIConfig: Codable {
    var endpoint: String
    var apiKey: String
    var model: String
    var enabled: Bool

    static let defaults = AIConfig(
        endpoint: "https://api.openai.com/v1",
        apiKey: "",
        model: "gpt-4o",
        enabled: false
    )
}

struct AIChatMessage: Identifiable, Codable {
    let id: String
    let role: String
    var content: String
    var timestamp: Date
}

struct AICommandResult: Codable {
    let command: String
    let output: String
    let exitCode: Int32
}

struct AISession: Codable, Identifiable {
    let id: String
    let serverId: String
    var title: String
    var messages: [AIChatMessage]
    var createdAt: Date
    var updatedAt: Date

    static func create(serverId: String) -> AISession {
        AISession(
            id: UUID().uuidString,
            serverId: serverId,
            title: "",
            messages: [],
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

struct HistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double
    let mem: Double
}

struct ServerProcess: Codable, Identifiable {
    let pid: UInt32
    let user: String
    let cpu: Double
    let mem: Double
    let vsz: UInt64
    let rss: UInt64
    let stat: String
    let command: String

    var id: UInt32 { pid }
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

extension Color {
    init?(hex: String) {
        var hexStr = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if hexStr.count == 3 {
            hexStr = hexStr.map { "\($0)\($0)" }.joined()
        }
        if hexStr.count == 6 {
            hexStr = "FF" + hexStr
        }
        guard hexStr.count == 8, let rgb = UInt64(hexStr, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0,
            opacity: Double((rgb >> 24) & 0xFF) / 255.0
        )
    }
}
