import Foundation

final class InventoryState: ObservableObject {
    @Published var servers: [Server] = []
    @Published var credentialGroups: [CredentialGroup] = []
    @Published var databaseConnections: [DatabaseConnection] = []
    @Published var databaseBackupRecords: [DatabaseBackupRecord] = []
    @Published var portForwardRules: [PortForwardRule] = []

    @Published var editingServer: Server?
    @Published var dialogDefaults: ServerInput?
    @Published var editingCg: CredentialGroup?
    @Published var editingDatabaseConnection: DatabaseConnection?
    @Published var databaseOperationLoading: Bool = false
    @Published var databasePanelSnapshots: [String: DatabasePanelSnapshot] = [:]

    let bridge = OrbitBridge.shared
}
