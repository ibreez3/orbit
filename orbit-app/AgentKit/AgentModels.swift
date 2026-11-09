import Foundation

public enum AgentExecMode: String, Codable, Sendable {
    case read
    case write
}

public enum AgentExecStatus: String, Codable, Sendable {
    case completed
    case running
    case timedOut = "timed_out"
    case failed
    case cancelled
}

public struct AgentExecResult: Codable, Equatable, Sendable {
    public var status: AgentExecStatus
    public var serverId: String
    public var stdout: String?
    public var stderr: String?
    public var exitCode: Int32?
    public var durationMs: UInt64
    public var truncated: Bool
    public var stdoutBytes: Int
    public var stderrBytes: Int
    public var jobId: String?
    public var mode: AgentExecMode
    public var escalated: Bool

    public init(
        status: AgentExecStatus,
        serverId: String,
        stdout: String? = nil,
        stderr: String? = nil,
        exitCode: Int32? = nil,
        durationMs: UInt64 = 0,
        truncated: Bool = false,
        stdoutBytes: Int = 0,
        stderrBytes: Int = 0,
        jobId: String? = nil,
        mode: AgentExecMode = .read,
        escalated: Bool = false
    ) {
        self.status = status
        self.serverId = serverId
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.truncated = truncated
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
        self.jobId = jobId
        self.mode = mode
        self.escalated = escalated
    }
}

public struct AgentServerSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var folder: String?
    public var tags: [String]
    public var aiEnabled: Bool

    public init(
        id: String,
        name: String,
        host: String,
        port: UInt16,
        username: String,
        folder: String?,
        tags: [String],
        aiEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.folder = folder
        self.tags = tags
        self.aiEnabled = aiEnabled
    }
}

public enum AgentErrorCode: String, Codable, Sendable {
    case unauthorized
    case admissionDenied = "admission_denied"
    case approvalTimeout = "approval_timeout"
    case serverNotFound = "server_not_found"
    case serverNotExposed = "server_not_exposed"
    case writeGrantRequired = "write_grant_required"
    case writeDenied = "write_denied"
    case commandTimeout = "command_timeout"
    case sessionExpired = "session_expired"
    case orbitUnavailable = "orbit_unavailable"
    case invalidRequest = "invalid_request"
    case shellNotFound = "shell_not_found"
    case shellTimeout = "shell_timeout"
}

public struct AgentErrorBody: Codable, Equatable, Sendable, Error {
    public var code: AgentErrorCode
    public var message: String

    public init(code: AgentErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AgentSessionCredential: Codable, Equatable, Sendable {
    public var sessionId: String
    public var token: String

    public init(sessionId: String, token: String) {
        self.sessionId = sessionId
        self.token = token
    }
}

public struct AgentHello: Codable, Equatable, Sendable {
    public var clientName: String
    public var clientVersion: String
    public var bridgeVersion: String
    public var parentPid: Int32
    public var parentPath: String

    public init(
        clientName: String,
        clientVersion: String,
        bridgeVersion: String,
        parentPid: Int32,
        parentPath: String
    ) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.bridgeVersion = bridgeVersion
        self.parentPid = parentPid
        self.parentPath = parentPath
    }
}

public enum AgentApprovalState: String, Codable, Sendable {
    case pending
    case approved
    case denied
    case expired
}

public struct AgentApprovalStatus: Codable, Equatable, Sendable {
    public var requestId: String
    public var status: AgentApprovalState
    public var session: AgentSessionCredential?
    public var error: AgentErrorBody?

    public init(
        requestId: String,
        status: AgentApprovalState,
        session: AgentSessionCredential? = nil,
        error: AgentErrorBody? = nil
    ) {
        self.requestId = requestId
        self.status = status
        self.session = session
        self.error = error
    }
}

public enum AgentAdmissionResult: Equatable, Sendable {
    case approved(AgentSessionCredential)
    case pending(requestId: String)
    case denied(AgentErrorBody)
}

public struct AgentJobStatus: Codable, Equatable, Sendable {
    public var jobId: String
    public var status: AgentExecStatus
    public var exitCode: Int32?
    public var durationMs: UInt64
    public var truncated: Bool

    public init(
        jobId: String,
        status: AgentExecStatus,
        exitCode: Int32?,
        durationMs: UInt64,
        truncated: Bool
    ) {
        self.jobId = jobId
        self.status = status
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.truncated = truncated
    }
}

public struct AgentJobOutput: Codable, Equatable, Sendable {
    public var jobId: String
    public var chunk: String
    public var nextCursor: Int
    public var eof: Bool
    public var truncated: Bool

    public init(
        jobId: String,
        chunk: String,
        nextCursor: Int,
        eof: Bool,
        truncated: Bool
    ) {
        self.jobId = jobId
        self.chunk = chunk
        self.nextCursor = nextCursor
        self.eof = eof
        self.truncated = truncated
    }
}

public struct AgentActiveSession: Codable, Equatable, Sendable {
    public var sessionId: String
    public var agentName: String
    public var createdAt: Date
    public var lastActivityAt: Date
    public var openJobCount: Int
    public var openShellCount: Int

    public init(
        sessionId: String,
        agentName: String,
        createdAt: Date,
        lastActivityAt: Date,
        openJobCount: Int,
        openShellCount: Int
    ) {
        self.sessionId = sessionId
        self.agentName = agentName
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.openJobCount = openJobCount
        self.openShellCount = openShellCount
    }
}

public enum AgentToolName {
    public static let listServers = "orbit_list_servers"
    public static let exec = "orbit_exec"
    public static let jobStatus = "orbit_job_status"
    public static let jobOutput = "orbit_job_output"
    public static let jobCancel = "orbit_job_cancel"
    public static let approvalStatus = "orbit_approval_status"
    public static let shellOpen = "orbit_shell_open"
    public static let shellExec = "orbit_shell_exec"
    public static let shellClose = "orbit_shell_close"
}
