import Foundation

final class InventoryState: ObservableObject {
    @Published var servers: [Server] = []
    @Published var credentialGroups: [CredentialGroup] = []
    @Published var portForwardRules: [PortForwardRule] = []

    @Published var editingServer: Server?
    @Published var dialogDefaults: ServerInput?
    @Published var editingCg: CredentialGroup?

    let bridge = OrbitBridge.shared
}
