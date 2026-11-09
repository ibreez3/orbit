import Darwin
import Foundation

public enum MCPID: Codable, Equatable, Sendable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        }
    }
}

public struct MCPError: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct MCPRequest: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: MCPID?
    public var method: String
    public var params: AgentJSONValue?

    public init(jsonrpc: String = "2.0", id: MCPID? = nil, method: String, params: AgentJSONValue? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct MCPResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: MCPID?
    public var result: AgentJSONValue?
    public var error: MCPError?

    public init(
        jsonrpc: String = "2.0",
        id: MCPID? = nil,
        result: AgentJSONValue? = nil,
        error: MCPError? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct MCPToolDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: AgentJSONValue

    public init(name: String, description: String, inputSchema: AgentJSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum AgentToolCatalog {
    public static let phase1Tools: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: AgentToolName.listServers,
            description: "List servers that the user has exposed to AI agents. Returns ids, names, hosts, folders, and tags.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false)
            ])
        ),
        MCPToolDefinition(
            name: AgentToolName.exec,
            description: "Execute one shell command over SSH on an exposed server. Read mode is immediate; write mode requires a one-time per-session approval. Long commands return a job id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "server": .object(["type": .string("string")]),
                    "command": .object(["type": .string("string")]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("read"), .string("write")]),
                        "default": .string("read")
                    ]),
                    "timeoutMs": .object([
                        "type": .string("integer"),
                        "minimum": .number(1),
                        "maximum": .number(300_000)
                    ]),
                    "waitMs": .object([
                        "type": .string("integer"),
                        "minimum": .number(1),
                        "maximum": .number(50_000)
                    ]),
                    "maxOutputBytes": .object([
                        "type": .string("integer"),
                        "minimum": .number(1),
                        "maximum": .number(1_048_576)
                    ]),
                    "idempotencyKey": .object(["type": .string("string")])
                ]),
                "required": .array([.string("server"), .string("command")]),
                "additionalProperties": .bool(false)
            ])
        ),
        MCPToolDefinition(
            name: AgentToolName.shellOpen,
            description: "Open a persistent SSH shell on an exposed server. Requires the one-time per-session write approval for that server.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "server": .object(["type": .string("string")])
                ]),
                "required": .array([.string("server")]),
                "additionalProperties": .bool(false)
            ])
        ),
        MCPToolDefinition(
            name: AgentToolName.shellExec,
            description: "Run a command in a persistent orbit_shell_open shell and wait for its completion marker. Use this when cd, environment variables, or interactive container shells must persist.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "shellId": .object(["type": .string("string")]),
                    "command": .object(["type": .string("string")]),
                    "timeoutMs": .object([
                        "type": .string("integer"),
                        "minimum": .number(1),
                        "maximum": .number(50_000)
                    ])
                ]),
                "required": .array([.string("shellId"), .string("command")]),
                "additionalProperties": .bool(false)
            ])
        ),
        MCPToolDefinition(
            name: AgentToolName.shellClose,
            description: "Close a persistent agent shell.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["shellId": .object(["type": .string("string")])]),
                "required": .array([.string("shellId")]),
                "additionalProperties": .bool(false)
            ])
        ),
        MCPToolDefinition(
            name: AgentToolName.jobStatus,
            description: "Get the status of a long-running orbit_exec job.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["jobId": .object(["type": .string("string")])]),
                "required": .array([.string("jobId")]),
                "additionalProperties": .bool(false)
            ])
        ),
        MCPToolDefinition(
            name: AgentToolName.jobOutput,
            description: "Read buffered output from a long-running orbit_exec job starting at a cursor.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "jobId": .object(["type": .string("string")]),
                    "cursor": .object(["type": .string("integer"), "minimum": .number(0)])
                ]),
                "required": .array([.string("jobId")]),
                "additionalProperties": .bool(false)
            ])
        ),
        MCPToolDefinition(
            name: AgentToolName.jobCancel,
            description: "Cancel a long-running orbit_exec job.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["jobId": .object(["type": .string("string")])]),
                "required": .array([.string("jobId")]),
                "additionalProperties": .bool(false)
            ])
        ),
        MCPToolDefinition(
            name: AgentToolName.approvalStatus,
            description: "Check whether a pending write approval has been granted in Orbit.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["requestId": .object(["type": .string("string")])]),
                "required": .array([.string("requestId")]),
                "additionalProperties": .bool(false)
            ])
        )
    ]
}

public final class MCPBridgeCore {
    private let client: AgentGatewayCalling
    private let tools: [MCPToolDefinition]
    private var session: AgentSessionCredential?
    private var pendingRequestId: String?
    private var clientName = "MCP Client"
    private var clientVersion = ""

    public init(
        client: AgentGatewayCalling,
        tools: [MCPToolDefinition] = AgentToolCatalog.phase1Tools
    ) {
        self.client = client
        self.tools = tools
    }

    public func handle(_ request: MCPRequest) -> MCPResponse? {
        switch request.method {
        case "initialize":
            if let info = request.params?.objectValue?["clientInfo"]?.objectValue {
                clientName = info["name"]?.stringValue ?? clientName
                clientVersion = info["version"]?.stringValue ?? ""
            }
            return MCPResponse(
                id: request.id,
                result: .object([
                    "protocolVersion": .string("2024-11-05"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object([
                        "name": .string("orbit"),
                        "version": .string("0.1.0")
                    ])
                ])
            )
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "tools/list":
            let encoded = (try? AgentJSONValue.encoding(tools)) ?? .array([])
            return MCPResponse(id: request.id, result: .object(["tools": encoded]))
        case "tools/call":
            return handleToolCall(request)
        case "ping":
            return MCPResponse(id: request.id, result: .object([:]))
        default:
            return MCPResponse(
                id: request.id,
                error: MCPError(code: -32601, message: "Method not found: \(request.method)")
            )
        }
    }

    private func handleToolCall(_ request: MCPRequest) -> MCPResponse {
        guard let params = request.params?.objectValue,
              let toolName = params["name"]?.stringValue else {
            return MCPResponse(
                id: request.id,
                error: MCPError(code: -32602, message: "tools/call requires a tool name")
            )
        }
        let arguments = params["arguments"] ?? .object([:])

        do {
            guard let credential = try ensureSession() else {
                return toolResponse(
                    id: request.id,
                    value: .object([
                        "status": .string("pending_approval"),
                        "requestId": .string(pendingRequestId ?? ""),
                        "message": .string("Approve this Agent in Orbit, then retry the same tool call.")
                    ])
                )
            }
            let result = try client.call(tool: toolName, args: arguments, session: credential)
            return toolResponse(id: request.id, value: result)
        } catch let error as AgentSocketClientError {
            switch error {
            case .remote(let body):
                if body.code == .writeGrantRequired {
                    return toolResponse(
                        id: request.id,
                        value: .object([
                            "status": .string("pending_approval"),
                            "message": .string(body.message)
                        ])
                    )
                }
                if body.code == .sessionExpired || body.code == .unauthorized {
                    session = nil
                    pendingRequestId = nil
                    return toolResponse(
                        id: request.id,
                        value: .object([
                            "status": .string("pending_approval"),
                            "message": .string(
                                "The Orbit session ended. Approve this Agent again, then retry the same tool call."
                            )
                        ])
                    )
                }
                if body.code == .orbitUnavailable {
                    session = nil
                    pendingRequestId = nil
                }
                return toolError(id: request.id, code: body.code.rawValue, message: body.message)
            default:
                switch error {
                case .notConnected, .connectFailed, .io:
                    session = nil
                    pendingRequestId = nil
                default:
                    break
                }
                return toolError(
                    id: request.id,
                    code: AgentErrorCode.orbitUnavailable.rawValue,
                    message: error.localizedDescription
                )
            }
        } catch {
            return toolError(
                id: request.id,
                code: AgentErrorCode.invalidRequest.rawValue,
                message: error.localizedDescription
            )
        }
    }

    private func ensureSession() throws -> AgentSessionCredential? {
        if let session {
            return session
        }
        if let pendingRequestId {
            let status = try client.approvalStatus(requestId: pendingRequestId)
            switch status.status {
            case .approved:
                guard let credential = status.session else {
                    throw AgentSocketClientError.invalidResponse
                }
                session = credential
                self.pendingRequestId = nil
                return credential
            case .pending:
                return nil
            case .denied, .expired:
                self.pendingRequestId = nil
                if let error = status.error {
                    throw AgentSocketClientError.remote(error)
                }
                throw AgentSocketClientError.remote(AgentErrorBody(
                    code: .admissionDenied,
                    message: "Orbit denied the agent connection"
                ))
            }
        }

        let parent = parentProcess()
        let hello = AgentHello(
            clientName: clientName,
            clientVersion: clientVersion,
            bridgeVersion: "0.1.0",
            parentPid: parent.pid,
            parentPath: parent.path
        )
        switch try client.hello(hello) {
        case .approved(let credential):
            session = credential
            return credential
        case .pending(let requestId):
            pendingRequestId = requestId
            return nil
        case .denied(let error):
            throw AgentSocketClientError.remote(error)
        }
    }

    private func toolResponse(id: MCPID?, value: AgentJSONValue) -> MCPResponse {
        let text = value.jsonString ?? "{}"
        return MCPResponse(
            id: id,
            result: .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ]),
                "isError": .bool(false)
            ])
        )
    }

    private func toolError(id: MCPID?, code: String, message: String) -> MCPResponse {
        let value = AgentJSONValue.object([
            "status": .string("error"),
            "code": .string(code),
            "message": .string(message)
        ])
        let text = value.jsonString ?? "{}"
        return MCPResponse(
            id: id,
            result: .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ]),
                "isError": .bool(true)
            ])
        )
    }

    private func parentProcess() -> (pid: Int32, path: String) {
        let pid = getppid()
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        return (pid, path)
    }
}
