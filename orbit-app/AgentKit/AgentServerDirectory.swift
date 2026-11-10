import Foundation

public enum AgentServerResolution: Equatable, Sendable {
    case resolved(AgentServerSummary)
    case notFound
    case ambiguous([AgentServerSummary])
    case notExposed
}

public struct AgentServerDirectory {
    private let servers: [AgentServerSummary]

    public init(servers: [AgentServerSummary]) {
        self.servers = servers
    }

    public func list() -> [AgentServerSummary] {
        servers
            .filter(\.aiEnabled)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func resolve(_ query: String) -> AgentServerResolution {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .notFound }

        if let server = servers.first(where: { $0.id == value }) {
            return server.aiEnabled ? .resolved(server) : .notExposed
        }
        if let result = resolve(matches: servers.filter { $0.name == value }) {
            return result
        }
        if let result = resolve(matches: servers.filter { $0.host == value }) {
            return result
        }
        return .notFound
    }

    private func resolve(matches: [AgentServerSummary]) -> AgentServerResolution? {
        guard !matches.isEmpty else { return nil }
        let exposed = matches.filter(\.aiEnabled)
        if exposed.count > 1 {
            return .ambiguous(exposed)
        }
        if let server = exposed.first {
            return .resolved(server)
        }
        return .notExposed
    }
}
