import Foundation

public protocol AgentGatewayCalling {
    func hello(_ hello: AgentHello) throws -> AgentAdmissionResult
    func approvalStatus(requestId: String) throws -> AgentApprovalStatus
    func call(tool: String, args: AgentJSONValue, session: AgentSessionCredential) throws -> AgentJSONValue
    func revoke(_ session: AgentSessionCredential) throws
}

public struct AgentExecRequest: Sendable {
    public var serverQuery: String
    public var command: String
    public var mode: AgentExecMode
    public var timeoutMs: UInt32
    public var waitMs: UInt32
    public var maxOutputBytes: UInt32
    public var idempotencyKey: String?
    public var sessionId: String?

    public init(
        serverQuery: String,
        command: String,
        mode: AgentExecMode,
        timeoutMs: UInt32,
        waitMs: UInt32,
        maxOutputBytes: UInt32,
        idempotencyKey: String?,
        sessionId: String? = nil
    ) {
        self.serverQuery = serverQuery
        self.command = command
        self.mode = mode
        self.timeoutMs = timeoutMs
        self.waitMs = waitMs
        self.maxOutputBytes = maxOutputBytes
        self.idempotencyKey = idempotencyKey
        self.sessionId = sessionId
    }
}

public protocol AgentCommandExecuting {
    func listServers() -> [AgentServerSummary]
    func exec(_ request: AgentExecRequest) async throws -> AgentExecResult
    func jobStatus(jobId: String) async throws -> AgentJobStatus
    func jobOutput(jobId: String, cursor: Int?) async throws -> AgentJobOutput
    func jobCancel(jobId: String) async throws
    func cancelJobs(serverId: String)
}

public struct AgentAdmissionRequest: Sendable {
    public var requestId: String
    public var agentName: String
    public var clientVersion: String
    public var parentPath: String
    public var parentPid: Int32

    public init(
        requestId: String,
        agentName: String,
        clientVersion: String,
        parentPath: String,
        parentPid: Int32
    ) {
        self.requestId = requestId
        self.agentName = agentName
        self.clientVersion = clientVersion
        self.parentPath = parentPath
        self.parentPid = parentPid
    }
}

public struct AgentWriteRequest: Sendable {
    public var requestId: String
    public var agentName: String
    public var serverId: String
    public var serverName: String
    public var command: String

    public init(
        requestId: String,
        agentName: String,
        serverId: String,
        serverName: String,
        command: String
    ) {
        self.requestId = requestId
        self.agentName = agentName
        self.serverId = serverId
        self.serverName = serverName
        self.command = command
    }
}

public protocol AgentApprovalPresenting {
    func requestAdmission(_ request: AgentAdmissionRequest) async -> Bool
    func requestWrite(_ request: AgentWriteRequest) async -> Bool
}

public struct AgentAuditEvent: Codable, Equatable, Sendable {
    public var id: String
    public var timestamp: Date
    public var type: String
    public var sessionId: String?
    public var agent: String?
    public var serverId: String?
    public var tool: String?
    public var command: String?
    public var mode: String?
    public var exitCode: Int32?
    public var durationMs: UInt64?
    public var stdoutBytes: Int?
    public var stderrBytes: Int?
    public var result: String?

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        type: String,
        sessionId: String? = nil,
        agent: String? = nil,
        serverId: String? = nil,
        tool: String? = nil,
        command: String? = nil,
        mode: String? = nil,
        exitCode: Int32? = nil,
        durationMs: UInt64? = nil,
        stdoutBytes: Int? = nil,
        stderrBytes: Int? = nil,
        result: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.sessionId = sessionId
        self.agent = agent
        self.serverId = serverId
        self.tool = tool
        self.command = command
        self.mode = mode
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
        self.result = result
    }
}

public protocol AgentAuditRecording {
    func record(_ event: AgentAuditEvent)
}
