import Foundation

public final class AgentExposureStore {
    public static let shared = AgentExposureStore(defaults: .standard)

    private let defaults: UserDefaults
    private let disabledKey = "agentDisabledServerIds"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func isEnabled(serverId: String) -> Bool {
        !disabledServerIds.contains(serverId)
    }

    public func setEnabled(_ enabled: Bool, serverId: String) {
        var disabled = disabledServerIds
        if enabled {
            disabled.remove(serverId)
        } else {
            disabled.insert(serverId)
        }
        defaults.set(Array(disabled).sorted(), forKey: disabledKey)
    }

    public func enabledServers(from servers: [AgentServerSummary]) -> [AgentServerSummary] {
        servers
            .filter { isEnabled(serverId: $0.id) }
            .map { server in
                var enabled = server
                enabled.aiEnabled = true
                return enabled
            }
    }

    private var disabledServerIds: Set<String> {
        Set(defaults.stringArray(forKey: disabledKey) ?? [])
    }
}
