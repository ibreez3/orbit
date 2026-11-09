import Foundation

public enum AgentSessionValidation: Equatable, Sendable {
    case valid
    case unauthorized
    case expired
}

public final class AgentSessionStore {
    private struct Session {
        let sessionId: String
        let token: String
        let agentName: String
        let createdAt: Date
        var lastActivityAt: Date
        var jobs: Set<String>
        var shells: Set<String>
        var writeServers: Set<String>
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private let clock: () -> Date
    private let idleTimeout: TimeInterval
    private let maxLifetime: TimeInterval

    public init(
        clock: @escaping () -> Date = Date.init,
        idleTimeout: TimeInterval = 1800,
        maxLifetime: TimeInterval = 8 * 3600
    ) {
        self.clock = clock
        self.idleTimeout = idleTimeout
        self.maxLifetime = maxLifetime
    }

    public func createSession(agentName: String) -> AgentSessionCredential {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        let sessionId = UUID().uuidString
        let token = Self.randomToken()
        sessions[sessionId] = Session(
            sessionId: sessionId,
            token: token,
            agentName: agentName,
            createdAt: now,
            lastActivityAt: now,
            jobs: [],
            shells: [],
            writeServers: []
        )
        return AgentSessionCredential(sessionId: sessionId, token: token)
    }

    public func touch(_ sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions[sessionId]?.lastActivityAt = clock()
    }

    public func validate(_ credential: AgentSessionCredential) -> AgentSessionValidation {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[credential.sessionId],
              Self.secureEquals(session.token, credential.token) else {
            return .unauthorized
        }
        let now = clock()
        if now.timeIntervalSince(session.createdAt) > maxLifetime {
            sessions.removeValue(forKey: credential.sessionId)
            return .expired
        }
        let busy = !session.jobs.isEmpty || !session.shells.isEmpty
        if !busy && now.timeIntervalSince(session.lastActivityAt) > idleTimeout {
            sessions.removeValue(forKey: credential.sessionId)
            return .expired
        }
        return .valid
    }

    public func grantWrite(sessionId: String, serverId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var session = sessions[sessionId] else { return }
        session.writeServers.insert(serverId)
        session.lastActivityAt = clock()
        sessions[sessionId] = session
    }

    public func hasWriteGrant(sessionId: String, serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionId]?.writeServers.contains(serverId) ?? false
    }

    public func agentName(sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionId]?.agentName
    }

    public func markJobActive(sessionId: String, jobId: String) {
        update(sessionId: sessionId) { session in
            session.jobs.insert(jobId)
        }
    }

    public func markJobFinished(sessionId: String, jobId: String) {
        update(sessionId: sessionId) { session in
            session.jobs.remove(jobId)
        }
    }

    public func markShellActive(sessionId: String, shellId: String) {
        update(sessionId: sessionId) { session in
            session.shells.insert(shellId)
        }
    }

    public func markShellClosed(sessionId: String, shellId: String) {
        update(sessionId: sessionId) { session in
            session.shells.remove(shellId)
        }
    }

    public func revoke(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: sessionId)
    }

    public func revokeServer(serverId: String) {
        lock.lock()
        defer { lock.unlock() }
        for (sessionId, var session) in sessions {
            session.writeServers.remove(serverId)
            sessions[sessionId] = session
        }
    }

    public func revokeAll() {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll()
    }

    public func activeSessions() -> [AgentActiveSession] {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked()
        return sessions.values
            .map { session in
                AgentActiveSession(
                    sessionId: session.sessionId,
                    agentName: session.agentName,
                    createdAt: session.createdAt,
                    lastActivityAt: session.lastActivityAt,
                    openJobCount: session.jobs.count,
                    openShellCount: session.shells.count
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public var hasActiveSessions: Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked()
        return !sessions.isEmpty
    }

    private func update(sessionId: String, _ body: (inout Session) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var session = sessions[sessionId] else { return }
        body(&session)
        session.lastActivityAt = clock()
        sessions[sessionId] = session
    }

    private func pruneExpiredLocked() {
        let now = clock()
        sessions = sessions.filter { _, session in
            if now.timeIntervalSince(session.createdAt) > maxLifetime {
                return false
            }
            let busy = !session.jobs.isEmpty || !session.shells.isEmpty
            if !busy && now.timeIntervalSince(session.lastActivityAt) > idleTimeout {
                return false
            }
            return true
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func secureEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
