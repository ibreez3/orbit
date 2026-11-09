import Darwin
import Foundation

public enum AgentSocketClientError: LocalizedError {
    case notConnected
    case connectFailed(String)
    case io(String)
    case timeout
    case invalidResponse
    case remote(AgentErrorBody)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Orbit agent gateway is not connected"
        case .connectFailed(let message):
            return "Could not connect to Orbit: \(message)"
        case .io(let message):
            return "Orbit agent socket error: \(message)"
        case .timeout:
            return "Orbit agent request timed out"
        case .invalidResponse:
            return "Orbit returned an invalid agent response"
        case .remote(let error):
            return error.message
        }
    }
}

public final class AgentSocketClient: AgentGatewayCalling {
    private let socketPath: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var readBuffer = Data()

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        close()
    }

    public func connect(timeout: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw AgentSocketClientError.connectFailed(String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let count = min(pathBytes.count, raw.count - 1)
            raw.copyBytes(from: pathBytes.prefix(count))
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, addressLength)
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(socketFD)
            throw AgentSocketClientError.connectFailed(message)
        }

        var noSignal: Int32 = 1
        _ = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        fd = socketFD
        _ = timeout
    }

    public func close() {
        lock.lock()
        let current = fd
        fd = -1
        readBuffer.removeAll(keepingCapacity: false)
        lock.unlock()
        if current >= 0 {
            shutdown(current, SHUT_RDWR)
            Darwin.close(current)
        }
    }

    public func send(_ request: AgentRequest, timeout: TimeInterval) throws -> AgentResponse {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else {
            throw AgentSocketClientError.notConnected
        }

        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try writeAll(data)
        return try readResponse(timeout: timeout)
    }

    public func hello(_ hello: AgentHello) throws -> AgentAdmissionResult {
        let args = AgentJSONValue.object([
            "clientName": .string(hello.clientName),
            "clientVersion": .string(hello.clientVersion),
            "bridgeVersion": .string(hello.bridgeVersion),
            "parentPid": .number(Double(hello.parentPid)),
            "parentPath": .string(hello.parentPath)
        ])
        let response = try send(
            AgentRequest(id: UUID().uuidString, op: .hello, args: args),
            timeout: 10
        )
        if response.ok == false {
            return .denied(response.error ?? AgentErrorBody(
                code: .admissionDenied,
                message: "Orbit denied agent admission"
            ))
        }
        guard case .object(let object)? = response.result else {
            throw AgentSocketClientError.invalidResponse
        }
        let status = object["status"]?.stringValue
        if status == "approved",
           let sessionId = object["sessionId"]?.stringValue,
           let token = object["token"]?.stringValue {
            return .approved(AgentSessionCredential(sessionId: sessionId, token: token))
        }
        if status == "pending_approval",
           let requestId = object["requestId"]?.stringValue {
            return .pending(requestId: requestId)
        }
        if case .object(let error)? = object["error"],
           let code = error["code"]?.stringValue.flatMap(AgentErrorCode.init(rawValue:)),
           let message = error["message"]?.stringValue {
            return .denied(AgentErrorBody(code: code, message: message))
        }
        return .denied(AgentErrorBody(
            code: .admissionDenied,
            message: "Orbit denied agent admission"
        ))
    }

    public func approvalStatus(requestId: String) throws -> AgentApprovalStatus {
        let response = try send(
            AgentRequest(
                id: UUID().uuidString,
                op: .admissionStatus,
                args: .object(["requestId": .string(requestId)])
            ),
            timeout: 5
        )
        guard response.ok, case .object(let object)? = response.result else {
            if let error = response.error {
                return AgentApprovalStatus(requestId: requestId, status: .denied, error: error)
            }
            throw AgentSocketClientError.invalidResponse
        }
        let state = object["status"]?.stringValue.flatMap(AgentApprovalState.init(rawValue:)) ?? .pending
        let session: AgentSessionCredential?
        if case .object(let sessionObject)? = object["session"],
           let sessionId = sessionObject["sessionId"]?.stringValue,
           let token = sessionObject["token"]?.stringValue {
            session = AgentSessionCredential(sessionId: sessionId, token: token)
        } else if let sessionId = object["sessionId"]?.stringValue,
                  let token = object["token"]?.stringValue {
            session = AgentSessionCredential(sessionId: sessionId, token: token)
        } else {
            session = nil
        }
        return AgentApprovalStatus(requestId: requestId, status: state, session: session)
    }

    public func call(
        tool: String,
        args: AgentJSONValue,
        session: AgentSessionCredential
    ) throws -> AgentJSONValue {
        let response = try send(
            AgentRequest(
                id: UUID().uuidString,
                op: .call,
                sessionId: session.sessionId,
                token: session.token,
                tool: tool,
                args: args
            ),
            timeout: 60
        )
        if !response.ok {
            throw AgentSocketClientError.remote(response.error ?? AgentErrorBody(
                code: .invalidRequest,
                message: "Orbit rejected the tool call"
            ))
        }
        return response.result ?? .null
    }

    public func revoke(_ session: AgentSessionCredential) throws {
        _ = try send(
            AgentRequest(
                id: UUID().uuidString,
                op: .revoke,
                sessionId: session.sessionId,
                token: session.token
            ),
            timeout: 5
        )
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    throw AgentSocketClientError.io(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }

    private func readResponse(timeout: TimeInterval) throws -> AgentResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                do {
                    return try JSONDecoder().decode(AgentResponse.self, from: Data(line))
                } catch {
                    throw AgentSocketClientError.invalidResponse
                }
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw AgentSocketClientError.timeout
            }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(max(1, remaining * 1000)))
            if ready == 0 {
                throw AgentSocketClientError.timeout
            }
            if ready < 0 {
                if errno == EINTR { continue }
                throw AgentSocketClientError.io(String(cString: strerror(errno)))
            }
            if (pollDescriptor.revents & Int16(POLLIN)) == 0 {
                continue
            }

            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 {
                throw AgentSocketClientError.io("connection closed")
            }
            readBuffer.append(chunk, count: count)
        }
    }
}

public extension AgentJSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: AgentJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
