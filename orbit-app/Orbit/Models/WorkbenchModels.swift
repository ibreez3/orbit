import Foundation

enum WorkbenchContextKind: Equatable {
    case none
    case terminal
    case localShell
    case database
}

enum ConnectionStatus: String, Codable {
    case disconnected
    case connecting
    case connected
    case closing
    case failed
}

struct SessionCapabilities: OptionSet, Codable {
    let rawValue: Int

    static let ai = SessionCapabilities(rawValue: 1 << 0)
    static let sftp = SessionCapabilities(rawValue: 1 << 1)
    static let monitor = SessionCapabilities(rawValue: 1 << 2)
    static let logs = SessionCapabilities(rawValue: 1 << 3)
    static let snippets = SessionCapabilities(rawValue: 1 << 4)
}

struct ActiveSessionContext: Equatable {
    var kind: WorkbenchContextKind
    var tabId: String?
    var paneId: String?
    var sessionId: String?
    var serverId: String?
    var serverName: String?
    var host: String?
    var username: String?
    var port: UInt16?
    var connectionStatus: ConnectionStatus
    var workingDirectory: String?
    var capabilities: SessionCapabilities

    var identity: String {
        [
            tabId ?? "none",
            paneId ?? "none",
            sessionId ?? "none",
            kindLabel
        ].joined(separator: ":")
    }

    var kindLabel: String {
        switch kind {
        case .none: return "none"
        case .terminal: return "terminal"
        case .localShell: return "local"
        case .database: return "database"
        }
    }

    static let empty = ActiveSessionContext(
        kind: .none,
        tabId: nil,
        paneId: nil,
        sessionId: nil,
        serverId: nil,
        serverName: nil,
        host: nil,
        username: nil,
        port: nil,
        connectionStatus: .disconnected,
        workingDirectory: nil,
        capabilities: []
    )
}

enum SessionTool: String, Codable, CaseIterable, Identifiable {
    case ai
    case sftp
    case monitor
    case logs
    case snippets

    var id: String { rawValue }
}

enum ToolPresentation: String, Codable {
    case floating
    case pinned
    case fullTab
}

struct BoundToolState: Equatable {
    var tool: SessionTool
    var presentation: ToolPresentation
    var boundContext: ActiveSessionContext
}

struct PendingAICommand: Equatable {
    var command: String
    var sessionId: String
    var tabId: String
    var contextIdentity: String
    var serverName: String?
    var host: String?
    var isHighRisk: Bool
    var riskReason: String?
}

struct DatabaseAIContext: Equatable {
    var selectedTable: String?
    var sqlText: String
    var resultSummary: String
}

enum AuditCategory: String, Codable {
    case connection
    case terminalCommand
    case aiAction
    case sftp
    case monitor
    case database
    case tool
    case error
}

enum AuditResult: String, Codable {
    case requested
    case authorized
    case denied
    case succeeded
    case failed
    case canceled
}

struct AuditEvent: Identifiable, Codable {
    var id: String
    var timestamp: Date
    var contextId: String
    var tabId: String?
    var sessionId: String?
    var serverId: String?
    var category: AuditCategory
    var action: String
    var target: String?
    var result: AuditResult
    var summary: String
}
