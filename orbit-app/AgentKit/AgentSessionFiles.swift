import Foundation

public struct AgentCLISession: Codable, Equatable, Sendable {
    public var sessionId: String
    public var clientName: String
    public var token: String
    public var createdAt: Date
    public var lastUsedAt: Date

    public init(
        sessionId: String,
        clientName: String,
        token: String,
        createdAt: Date,
        lastUsedAt: Date
    ) {
        self.sessionId = sessionId
        self.clientName = clientName
        self.token = token
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public final class AgentSessionFileStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    @discardableResult
    public func save(_ credential: AgentSessionCredential, clientName: String) throws -> AgentCLISession {
        try ensureDirectory()
        let now = Date()
        let record = AgentCLISession(
            sessionId: credential.sessionId,
            clientName: clientName,
            token: credential.token,
            createdAt: now,
            lastUsedAt: now
        )
        let data = try encoder.encode(record)
        let url = fileURL(for: credential.sessionId)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return record
    }

    public func load(clientName: String?, sessionId: String?) -> AgentSessionCredential? {
        if let sessionId {
            guard let record = session(at: fileURL(for: sessionId)) else { return nil }
            return AgentSessionCredential(sessionId: record.sessionId, token: record.token)
        }
        let candidates = list().filter { session in
            guard let clientName, !clientName.isEmpty else { return true }
            return session.clientName == clientName
        }
        guard let latest = candidates.first else { return nil }
        return AgentSessionCredential(sessionId: latest.sessionId, token: latest.token)
    }

    public func list() -> [AgentCLISession] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { session(at: $0) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public func remove(sessionId: String) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionId))
    }

    private func session(at url: URL) -> AgentCLISession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(AgentCLISession.self, from: data)
    }

    private func fileURL(for sessionId: String) -> URL {
        directory.appendingPathComponent("\(sessionId).json")
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
