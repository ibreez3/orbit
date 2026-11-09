import Darwin
import Foundation

public enum AgentCLIError: LocalizedError {
    case usage(String)
    case missingSession
    case denied(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .missingSession:
            return "No agent session. Run `orbit-cli auth --client <name>` first."
        case .denied(let message):
            return message
        }
    }
}

public enum AgentCLI {
    public static func run(
        arguments: [String],
        client: AgentGatewayCalling,
        sessions: AgentSessionFileStore,
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) throws {
        guard let command = arguments.first else {
            throw AgentCLIError.usage("Usage: orbit-cli <auth|servers|exec|job> ...")
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "auth":
            try runAuth(rest, client: client, sessions: sessions, stdout: stdout)
        case "servers":
            try runServers(rest, client: client, sessions: sessions, stdout: stdout)
        case "exec":
            try runExec(rest, client: client, sessions: sessions, stdout: stdout)
        case "job":
            try runJob(rest, client: client, sessions: sessions, stdout: stdout)
        default:
            throw AgentCLIError.usage("Unknown command: \(command)")
        }
    }

    private static func runAuth(
        _ arguments: [String],
        client: AgentGatewayCalling,
        sessions: AgentSessionFileStore,
        stdout: (String) -> Void
    ) throws {
        let parsed = parse(arguments)
        let clientName = parsed.options["--client"] ?? "AI Agent"
        let parent = parentProcess()
        let hello = AgentHello(
            clientName: clientName,
            clientVersion: "orbit-cli",
            bridgeVersion: "0.1.0",
            parentPid: parent.pid,
            parentPath: parent.path
        )

        var credential: AgentSessionCredential?
        switch try client.hello(hello) {
        case .approved(let value):
            credential = value
        case .denied(let error):
            throw AgentCLIError.denied(error.message)
        case .pending(let requestId):
            credential = try waitForApproval(
                requestId: requestId,
                client: client
            )
        }

        guard let credential else {
            throw AgentCLIError.denied("Orbit did not issue an agent session")
        }
        let record = try sessions.save(credential, clientName: clientName)
        let payload: [String: String] = [
            "sessionId": record.sessionId,
            "client": record.clientName
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            stdout(text)
        }
        stdout("export ORBIT_AGENT_SESSION=\(record.sessionId)")
    }

    private static func waitForApproval(
        requestId: String,
        client: AgentGatewayCalling
    ) throws -> AgentSessionCredential {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let status = try client.approvalStatus(requestId: requestId)
            switch status.status {
            case .approved:
                guard let session = status.session else {
                    throw AgentCLIError.denied("Orbit approved without a session credential")
                }
                return session
            case .denied, .expired:
                throw AgentCLIError.denied(
                    status.error?.message ?? "Orbit denied the agent connection"
                )
            case .pending:
                Thread.sleep(forTimeInterval: 1)
            }
        }
        throw AgentCLIError.denied("Timed out waiting for Orbit approval")
    }

    private static func runServers(
        _ arguments: [String],
        client: AgentGatewayCalling,
        sessions: AgentSessionFileStore,
        stdout: (String) -> Void
    ) throws {
        let parsed = parse(arguments)
        let session = try resolveSession(parsed, sessions: sessions)
        let result = try client.call(
            tool: AgentToolName.listServers,
            args: .object([:]),
            session: session
        )
        stdout(result.jsonString ?? "{}")
    }

    private static func runExec(
        _ arguments: [String],
        client: AgentGatewayCalling,
        sessions: AgentSessionFileStore,
        stdout: (String) -> Void
    ) throws {
        let parsed = parse(arguments)
        let session = try resolveSession(parsed, sessions: sessions)
        guard let server = parsed.options["--server"], !server.isEmpty else {
            throw AgentCLIError.usage("exec requires --server")
        }
        let command = parsed.positional.joined(separator: " ")
        guard !command.isEmpty else {
            throw AgentCLIError.usage("exec requires a command after --")
        }
        let mode = parsed.options["--mode"] ?? "read"
        guard mode == "read" || mode == "write" else {
            throw AgentCLIError.usage("--mode must be read or write")
        }

        var argumentsObject: [String: AgentJSONValue] = [
            "server": .string(server),
            "command": .string(command),
            "mode": .string(mode)
        ]
        if let value = parsed.options["--timeout-ms"], let number = Double(value) {
            argumentsObject["timeoutMs"] = .number(number)
        }
        if let value = parsed.options["--wait-ms"], let number = Double(value) {
            argumentsObject["waitMs"] = .number(number)
        }
        if let value = parsed.options["--max-output-bytes"], let number = Double(value) {
            argumentsObject["maxOutputBytes"] = .number(number)
        }
        if let value = parsed.options["--idempotency-key"] {
            argumentsObject["idempotencyKey"] = .string(value)
        }

        let result = try client.call(
            tool: AgentToolName.exec,
            args: .object(argumentsObject),
            session: session
        )
        stdout(result.jsonString ?? "{}")
    }

    private static func runJob(
        _ arguments: [String],
        client: AgentGatewayCalling,
        sessions: AgentSessionFileStore,
        stdout: (String) -> Void
    ) throws {
        guard let subcommand = arguments.first else {
            throw AgentCLIError.usage("Usage: orbit-cli job <status|output|cancel> --job <id> ...")
        }
        let parsed = parse(Array(arguments.dropFirst()))
        guard let jobId = parsed.options["--job"] ?? parsed.positional.first,
              !jobId.isEmpty else {
            throw AgentCLIError.usage("job requires --job <id>")
        }
        let session = try resolveSession(parsed, sessions: sessions)

        var argumentsObject: [String: AgentJSONValue] = ["jobId": .string(jobId)]
        let tool: String
        switch subcommand {
        case "status":
            tool = AgentToolName.jobStatus
        case "output":
            tool = AgentToolName.jobOutput
            if let rawCursor = parsed.options["--cursor"] {
                guard let cursor = Int(rawCursor), cursor >= 0 else {
                    throw AgentCLIError.usage("--cursor must be a non-negative integer")
                }
                argumentsObject["cursor"] = .number(Double(cursor))
            }
        case "cancel":
            tool = AgentToolName.jobCancel
        default:
            throw AgentCLIError.usage("Unknown job command: \(subcommand)")
        }

        let result = try client.call(
            tool: tool,
            args: .object(argumentsObject),
            session: session
        )
        stdout(result.jsonString ?? "{}")
    }

    private static func resolveSession(
        _ parsed: ParsedArguments,
        sessions: AgentSessionFileStore
    ) throws -> AgentSessionCredential {
        let sessionId = parsed.options["--session"]
            ?? ProcessInfo.processInfo.environment["ORBIT_AGENT_SESSION"]
        let clientName = parsed.options["--client"]
        guard let session = sessions.load(clientName: clientName, sessionId: sessionId) else {
            throw AgentCLIError.missingSession
        }
        return session
    }

    private struct ParsedArguments {
        var options: [String: String]
        var positional: [String]
    }

    private static func parse(_ arguments: [String]) -> ParsedArguments {
        var options: [String: String] = [:]
        var positional: [String] = []
        var afterSeparator = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if afterSeparator {
                positional.append(argument)
                index += 1
            } else if argument == "--" {
                afterSeparator = true
                index += 1
            } else if argument.hasPrefix("--") {
                if index + 1 < arguments.count {
                    options[argument] = arguments[index + 1]
                    index += 2
                } else {
                    options[argument] = ""
                    index += 1
                }
            } else {
                positional.append(argument)
                index += 1
            }
        }
        return ParsedArguments(options: options, positional: positional)
    }

    private static func parentProcess() -> (pid: Int32, path: String) {
        let pid = getppid()
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        return (pid, path)
    }
}
