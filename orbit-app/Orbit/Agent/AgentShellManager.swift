import AgentKit
import Foundation

protocol AgentShellTransport {
    func connect(serverId: String) async throws -> String
    func openShell(baseSessionId: String) async throws -> String
    func write(shellId: String, data: Data) throws
    func close(shellId: String) async
    func setOutputHandler(shellId: String, handler: @escaping (Data) -> Void)
}

protocol AgentShellManaging: AnyObject {
    func open(serverId: String, sessionId: String) async throws -> String
    func exec(shellId: String, command: String, timeout: TimeInterval) async throws -> AgentShellCommandResult
    func close(shellId: String) async
    func closeAll() async
    func closeAll(sessionId: String) async
    func closeAll(serverId: String) async
    func owner(shellId: String) -> (sessionId: String, serverId: String)?
}

enum AgentShellError: LocalizedError, Equatable {
    case writeRequired
    case shellNotFound
    case busy
    case timeout
    case closed
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .writeRequired:
            return "A write grant is required before opening a shell"
        case .shellNotFound:
            return "Shell not found"
        case .busy:
            return "A command is already running in this shell"
        case .timeout:
            return "Shell command timed out waiting for completion"
        case .closed:
            return "Shell was closed"
        case .transport(let message):
            return message
        }
    }
}

final class AgentShellManager: AgentShellManaging {
    private struct PendingCommand {
        let sentinel: AgentShellSentinel
        let continuation: CheckedContinuation<AgentShellCommandResult, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct Shell {
        let id: String
        let baseSessionId: String
        let serverId: String
        let sessionId: String
        var buffer: String
        var truncated: Bool
        var pending: PendingCommand?
    }

    let sessions: AgentSessionStore
    private let transport: AgentShellTransport
    private let maxOutputBytes: Int
    private let lock = NSLock()
    private var shells: [String: Shell] = [:]
    private var baseSessions: [String: String] = [:]

    init(
        transport: AgentShellTransport,
        sessions: AgentSessionStore,
        maxOutputBytes: Int = 1_048_576
    ) {
        self.transport = transport
        self.sessions = sessions
        self.maxOutputBytes = max(1, maxOutputBytes)
    }

    func open(serverId: String, sessionId: String) async throws -> String {
        guard sessions.hasWriteGrant(sessionId: sessionId, serverId: serverId) else {
            throw AgentShellError.writeRequired
        }
        let baseSessionId = try await baseSession(for: serverId)
        let shellId = try await transport.openShell(baseSessionId: baseSessionId)
        let shell = Shell(
            id: shellId,
            baseSessionId: baseSessionId,
            serverId: serverId,
            sessionId: sessionId,
            buffer: "",
            truncated: false,
            pending: nil
        )
        insertShell(shell)
        transport.setOutputHandler(shellId: shellId) { [weak self] data in
            self?.receive(shellId: shellId, data: data)
        }
        sessions.markShellActive(sessionId: sessionId, shellId: shellId)
        return shellId
    }

    func exec(
        shellId: String,
        command: String,
        timeout: TimeInterval
    ) async throws -> AgentShellCommandResult {
        let sentinel = AgentShellSentinel(uuid: UUID().uuidString)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard var shell = shells[shellId] else {
                lock.unlock()
                continuation.resume(throwing: AgentShellError.shellNotFound)
                return
            }
            guard shell.pending == nil else {
                lock.unlock()
                continuation.resume(throwing: AgentShellError.busy)
                return
            }

            let safeTimeout = timeout.isFinite ? timeout : 0.001
            let seconds = min(max(safeTimeout, 0.001), 300)
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(shellId: shellId, result: .failure(AgentShellError.timeout))
            }
            shell.buffer = ""
            shell.truncated = false
            shell.pending = PendingCommand(
                sentinel: sentinel,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            shells[shellId] = shell
            lock.unlock()

            let payload = "\(command)\n\(sentinel.commandSuffix())\n"
            do {
                try transport.write(shellId: shellId, data: Data(payload.utf8))
            } catch {
                finish(
                    shellId: shellId,
                    result: .failure(AgentShellError.transport(error.localizedDescription))
                )
            }
        }
    }

    func close(shellId: String) async {
        guard let shell = removeShell(shellId) else { return }

        finishPending(shell, error: AgentShellError.closed)
        sessions.markShellClosed(sessionId: shell.sessionId, shellId: shellId)
        await transport.close(shellId: shellId)
    }

    func closeAll() async {
        let (allShells, allBaseSessions) = takeAllShells()

        for shell in allShells.values {
            finishPending(shell, error: AgentShellError.closed)
            sessions.markShellClosed(sessionId: shell.sessionId, shellId: shell.id)
            await transport.close(shellId: shell.id)
        }
        for baseSessionId in allBaseSessions.values {
            await transport.close(shellId: baseSessionId)
        }
    }

    func closeAll(sessionId: String) async {
        let (matching, baseSessionsToClose) = takeShells(sessionId: sessionId)

        for shell in matching {
            finishPending(shell, error: AgentShellError.closed)
            sessions.markShellClosed(sessionId: shell.sessionId, shellId: shell.id)
            await transport.close(shellId: shell.id)
        }
        for baseSessionId in baseSessionsToClose {
            await transport.close(shellId: baseSessionId)
        }
    }

    func closeAll(serverId: String) async {
        let (matching, baseSessionId) = takeShells(serverId: serverId)

        for shell in matching {
            finishPending(shell, error: AgentShellError.closed)
            sessions.markShellClosed(sessionId: shell.sessionId, shellId: shell.id)
            await transport.close(shellId: shell.id)
        }
        if let baseSessionId {
            await transport.close(shellId: baseSessionId)
        }
    }

    func owner(shellId: String) -> (sessionId: String, serverId: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let shell = shells[shellId] else { return nil }
        return (shell.sessionId, shell.serverId)
    }

    private func baseSession(for serverId: String) async throws -> String {
        if let existing = cachedBaseSession(for: serverId) {
            return existing
        }

        let created = try await transport.connect(serverId: serverId)
        let stored = storeBaseSession(created, for: serverId)
        if stored != created {
            await transport.close(shellId: created)
        }
        return stored
    }

    private func insertShell(_ shell: Shell) {
        lock.lock()
        shells[shell.id] = shell
        lock.unlock()
    }

    private func removeShell(_ shellId: String) -> Shell? {
        lock.lock()
        defer { lock.unlock() }
        return shells.removeValue(forKey: shellId)
    }

    private func takeAllShells() -> ([String: Shell], [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        let allShells = shells
        let allBaseSessions = baseSessions
        shells.removeAll()
        baseSessions.removeAll()
        return (allShells, allBaseSessions)
    }

    private func takeShells(sessionId: String) -> ([Shell], [String]) {
        lock.lock()
        defer { lock.unlock() }
        let matching = shells.filter { $0.value.sessionId == sessionId }
        for shellId in matching.keys {
            shells.removeValue(forKey: shellId)
        }
        var baseSessionsToClose: [String] = []
        for serverId in Set(matching.values.map(\.serverId)) {
            let stillUsed = shells.values.contains { $0.serverId == serverId }
            if !stillUsed, let baseSessionId = baseSessions.removeValue(forKey: serverId) {
                baseSessionsToClose.append(baseSessionId)
            }
        }
        return (Array(matching.values), baseSessionsToClose)
    }

    private func takeShells(serverId: String) -> ([Shell], String?) {
        lock.lock()
        defer { lock.unlock() }
        let matching = shells.filter { $0.value.serverId == serverId }
        for shellId in matching.keys {
            shells.removeValue(forKey: shellId)
        }
        let baseSessionId = baseSessions.removeValue(forKey: serverId)
        return (Array(matching.values), baseSessionId)
    }

    private func cachedBaseSession(for serverId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return baseSessions[serverId]
    }

    private func storeBaseSession(_ baseSessionId: String, for serverId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = baseSessions[serverId] {
            return existing
        }
        baseSessions[serverId] = baseSessionId
        return baseSessionId
    }

    private func receive(shellId: String, data: Data) {
        lock.lock()
        guard var shell = shells[shellId],
              let pending = shell.pending else {
            lock.unlock()
            return
        }
        shell.buffer += String(decoding: data, as: UTF8.self)
        if shell.buffer.utf8.count > maxOutputBytes {
            // Keep the tail so the completion marker remains reachable while
            // bounding memory for commands such as yes or tail -f.
            let tail = shell.buffer.utf8.suffix(maxOutputBytes)
            shell.buffer = String(decoding: tail, as: UTF8.self)
            shell.truncated = true
        }
        var buffer = shell.buffer
        if var result = pending.sentinel.consume(buffer: &buffer) {
            result.truncated = shell.truncated
            shell.pending = nil
            shell.buffer = ""
            shells[shellId] = shell
            lock.unlock()
            pending.timeoutTask.cancel()
            sessions.touch(shell.sessionId)
            pending.continuation.resume(returning: result)
        } else {
            shell.buffer = buffer
            shells[shellId] = shell
            lock.unlock()
        }
    }

    private func finish(shellId: String, result: Result<AgentShellCommandResult, Error>) {
        lock.lock()
        guard var shell = shells[shellId],
              let pending = shell.pending else {
            lock.unlock()
            return
        }
        shell.pending = nil
        shell.buffer = ""
        shells[shellId] = shell
        let sessionId = shell.sessionId
        lock.unlock()

        pending.timeoutTask.cancel()
        if case .success = result {
            sessions.touch(sessionId)
        }
        pending.continuation.resume(with: result)
    }

    private func finishPending(_ shell: Shell, error: AgentShellError) {
        guard let pending = shell.pending else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }
}

extension OrbitBridge: AgentShellTransport {
    func connect(serverId: String) async throws -> String {
        try await connectSSHAsync(serverId: serverId)
    }

    func openShell(baseSessionId: String) async throws -> String {
        try await spawnChannelAsync(existingSessionId: baseSessionId)
    }

    func write(shellId: String, data: Data) throws {
        try writeSSH(sessionId: shellId, data: data)
    }

    func close(shellId: String) async {
        try? await disconnectSSHAsync(sessionId: shellId)
    }

    func setOutputHandler(shellId: String, handler: @escaping (Data) -> Void) {
        setSSHHandlers(sessionId: shellId, dataHandler: handler, closedHandler: {})
    }
}
