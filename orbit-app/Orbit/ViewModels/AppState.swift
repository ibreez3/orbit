import AppKit
import SwiftUI

class AppState: ObservableObject {
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    let tabState = TabState()
    let uiState = UIState()
    let themeState = ThemeState()
    let inventoryState: InventoryState
    let snippetState = SnippetState()
    let toolState = ToolState()
    let aiState = AIState()

    let sftpDrawer = SftpDrawerState()

    private var pendingQuitTabId: String? = nil

    @Published var databaseConnectionDialogOpen: Bool = false
    @Published private var databasePanelInvalidationTokens: [String: Int] = [:]
    @Published private(set) var serverOrganization = ServerOrganizationSnapshot.empty

    var tabs: [TabItem] {
        get { tabState.tabs }
        set { tabState.tabs = newValue }
    }

    var activeTabId: String? {
        get { tabState.activeTabId }
        set { tabState.activeTabId = newValue }
    }

    var activeTabError: String? {
        get { tabState.activeTabError }
        set { tabState.activeTabError = newValue }
    }

    var spotlightOpen: Bool {
        get { uiState.spotlightOpen }
        set { uiState.spotlightOpen = newValue }
    }

    var spotlightQuery: String {
        get { uiState.spotlightQuery }
        set { uiState.spotlightQuery = newValue }
    }

    var dialogOpen: Bool {
        get { uiState.dialogOpen }
        set { uiState.dialogOpen = newValue }
    }

    var cgDialogOpen: Bool {
        get { uiState.cgDialogOpen }
        set { uiState.cgDialogOpen = newValue }
    }

    var showQuitConfirmation: Bool {
        get { uiState.showQuitConfirmation }
        set { uiState.showQuitConfirmation = newValue }
    }

    var pendingCloseTabId: String? {
        get { uiState.pendingCloseTabId }
        set { uiState.pendingCloseTabId = newValue }
    }

    var assetTreeWidth: CGFloat {
        get { uiState.assetTreeWidth }
        set { uiState.assetTreeWidth = newValue }
    }

    var assetTreeSearchQuery: String {
        get { uiState.assetTreeSearchQuery }
        set { uiState.assetTreeSearchQuery = newValue }
    }

    var recentServers: [String] {
        get { uiState.recentServers }
        set { uiState.recentServers = newValue }
    }

    var theme: AppTheme {
        get { themeState.theme }
        set { themeState.theme = newValue }
    }

    var keywordHighlights: [KeywordHighlight] {
        get { themeState.keywordHighlights }
        set { themeState.keywordHighlights = newValue }
    }

    var showAlert: Binding<Bool> { uiState.showAlert }

    var alertMessage: String? {
        get { uiState.alertMessage }
        set { uiState.alertMessage = newValue }
    }
    var alertTitle: String {
        get { uiState.alertTitle }
        set { uiState.alertTitle = newValue }
    }

    let bridge = OrbitBridge.shared
    let workspaceBridge: any ServerWorkspaceBridge
    let textEditorWC = TextEditorWindowController()

    // MARK: - Inventory forwarding

    var servers: [Server] {
        get { inventoryState.servers }
        set { inventoryState.servers = newValue }
    }
    var credentialGroups: [CredentialGroup] {
        get { inventoryState.credentialGroups }
        set { inventoryState.credentialGroups = newValue }
    }
    var databaseConnections: [DatabaseConnection] {
        get { inventoryState.databaseConnections }
        set { inventoryState.databaseConnections = newValue }
    }
    var databaseBackupRecords: [DatabaseBackupRecord] {
        get { inventoryState.databaseBackupRecords }
        set { inventoryState.databaseBackupRecords = newValue }
    }
    var portForwardRules: [PortForwardRule] {
        get { inventoryState.portForwardRules }
        set { inventoryState.portForwardRules = newValue }
    }
    var editingServer: Server? {
        get { inventoryState.editingServer }
        set { inventoryState.editingServer = newValue }
    }
    var dialogDefaults: ServerInput? {
        get { inventoryState.dialogDefaults }
        set { inventoryState.dialogDefaults = newValue }
    }
    var editingCg: CredentialGroup? {
        get { inventoryState.editingCg }
        set { inventoryState.editingCg = newValue }
    }
    var editingDatabaseConnection: DatabaseConnection? {
        get { inventoryState.editingDatabaseConnection }
        set { inventoryState.editingDatabaseConnection = newValue }
    }
    var databaseOperationLoading: Bool {
        get { inventoryState.databaseOperationLoading }
        set { inventoryState.databaseOperationLoading = newValue }
    }
    var databasePanelSnapshots: [String: DatabasePanelSnapshot] {
        get { toolState.databasePanelSnapshots }
        set { toolState.databasePanelSnapshots = newValue }
    }

    // MARK: - Snippet forwarding

    var snippets: [CommandSnippet] {
        get { snippetState.snippets }
        set { snippetState.snippets = newValue }
    }
    var snippetEditorOpen: Bool {
        get { snippetState.snippetEditorOpen }
        set { snippetState.snippetEditorOpen = newValue }
    }
    var editingSnippet: CommandSnippet? {
        get { snippetState.editingSnippet }
        set { snippetState.editingSnippet = newValue }
    }

    // MARK: - Tool forwarding

    var activeTool: BoundToolState? {
        get { toolState.activeTool }
        set { toolState.activeTool = newValue }
    }
    var floatingToolWidth: CGFloat {
        get { toolState.floatingToolWidth }
        set { toolState.floatingToolWidth = newValue }
    }
    var floatingToolHeight: CGFloat {
        get { toolState.floatingToolHeight }
        set { toolState.floatingToolHeight = newValue }
    }
    var pendingContextSwitchTabId: String? {
        get { toolState.pendingContextSwitchTabId }
        set { toolState.pendingContextSwitchTabId = newValue }
    }
    var pendingContextSwitchMessage: String? {
        get { toolState.pendingContextSwitchMessage }
        set { toolState.pendingContextSwitchMessage = newValue }
    }
    var activeSftpTransferTabIds: Set<String> {
        get { toolState.activeSftpTransferTabIds }
        set { toolState.activeSftpTransferTabIds = newValue }
    }
    var dockerPanelSnapshots: [String: DockerPanelSnapshot] {
        get { toolState.dockerPanelSnapshots }
        set { toolState.dockerPanelSnapshots = newValue }
    }
    var aiPanelOpen: Bool {
        get { toolState.aiPanelOpen }
        set { toolState.aiPanelOpen = newValue }
    }

    // MARK: - AI forwarding

    var aiConfig: AIConfig {
        get { aiState.aiConfig }
        set { aiState.aiConfig = newValue }
    }
    var aiSessions: [String: [AISession]] {
        get { aiState.aiSessions }
        set { aiState.aiSessions = newValue }
    }
    var activeAISessionId: [String: String] {
        get { aiState.activeAISessionId }
        set { aiState.activeAISessionId = newValue }
    }
    var aiLoading: Bool {
        get { aiState.aiLoading }
        set { aiState.aiLoading = newValue }
    }
    var aiPanelWidth: CGFloat {
        get { aiState.aiPanelWidth }
        set { aiState.aiPanelWidth = newValue }
    }
    var aiPendingConfirmation: PendingAICommand? {
        get { aiState.aiPendingConfirmation }
        set { aiState.aiPendingConfirmation = newValue }
    }
    var databaseAIContexts: [String: DatabaseAIContext] {
        get { aiState.databaseAIContexts }
        set { aiState.databaseAIContexts = newValue }
    }
    var auditEventsByContext: [String: [AuditEvent]] {
        get { aiState.auditEventsByContext }
        set { aiState.auditEventsByContext = newValue }
    }

    var activeSessionContext: ActiveSessionContext {
        guard let activeTabId,
              let tab = tabs.first(where: { $0.id == activeTabId }) else {
            return .empty
        }

        let focusedSessionId = tab.focusedChannelId ?? tab.sessionId

        if tab.type == .database {
            return ActiveSessionContext(
                kind: .database,
                tabId: tab.id,
                paneId: nil,
                sessionId: nil,
                serverId: tab.serverId,
                serverName: tab.serverName,
                host: nil,
                username: nil,
                port: nil,
                connectionStatus: .connected,
                workingDirectory: nil,
                capabilities: [.ai, .logs]
            )
        }

        if case .local = tab.connectionTarget {
            return ActiveSessionContext(
                kind: .localShell,
                tabId: tab.id,
                paneId: focusedSessionId,
                sessionId: focusedSessionId,
                serverId: tab.serverId,
                serverName: tab.serverName,
                host: nil,
                username: NSUserName(),
                port: nil,
                connectionStatus: focusedSessionId == nil ? .disconnected : .connected,
                workingDirectory: nil,
                capabilities: [.ai, .logs, .snippets]
            )
        }

        if case .temporary(let tabId) = tab.connectionTarget {
            let draft = temporaryDraft(for: tabId)
            return ActiveSessionContext(
                kind: .terminal,
                tabId: tab.id,
                paneId: focusedSessionId,
                sessionId: focusedSessionId,
                serverId: nil,
                serverName: tab.serverName,
                host: draft?.host,
                username: draft?.username,
                port: draft?.port,
                connectionStatus: focusedSessionId == nil ? .connecting : .connected,
                workingDirectory: nil,
                capabilities: [.ai, .logs, .snippets]
            )
        }

        let server = servers.first(where: { $0.id == tab.serverId })
        let status: ConnectionStatus
        if focusedSessionId != nil {
            status = .connected
        } else if tab.type == .terminal {
            status = .connecting
        } else {
            status = .disconnected
        }

        return ActiveSessionContext(
            kind: tab.type == .terminal ? .terminal : .none,
            tabId: tab.id,
            paneId: focusedSessionId,
            sessionId: focusedSessionId,
            serverId: tab.serverId,
            serverName: tab.serverName,
            host: server?.host,
            username: server?.username,
            port: server?.port,
            connectionStatus: status,
            workingDirectory: nil,
            capabilities: tab.type == .terminal ? [.ai, .sftp, .monitor, .logs, .snippets] : [.logs]
        )
    }

    init(workspaceBridge: any ServerWorkspaceBridge = OrbitBridge.shared) {
        self.workspaceBridge = workspaceBridge
        self.inventoryState = InventoryState(bridge: workspaceBridge)
        ThemeManager.shared.loadThemes()
        loadServers()
        loadServerOrganization()
        loadCredentialGroups()
        loadDatabaseConnections()
        loadDatabaseBackupRecords()
        loadSnippets()
        loadKeywords()
        loadAIConfig()
        loadAIPanelWidth()
        loadAssetTreeWidth()
        loadRecentServers()
        loadPortForwardRules()
    }

    func loadServers() {
        Task {
            do {
                let result = try bridge.listServers()
                await MainActor.run { self.servers = result }
            } catch {
                await MainActor.run {
                    alertTitle = "加载失败"
                    alertMessage = "无法加载服务器列表: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadServerOrganization() {
        Task {
            do {
                let result = try await workspaceBridge.listServerOrganizationAsync()
                await MainActor.run { self.serverOrganization = result }
            } catch {
                await MainActor.run {
                    alertTitle = "加载失败"
                    alertMessage = "无法加载服务器目录与标签: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadCredentialGroups() {
        Task {
            do {
                let result = try bridge.listCredentialGroups()
                await MainActor.run { self.credentialGroups = result }
            } catch {
                await MainActor.run {
                    alertTitle = "加载失败"
                    alertMessage = "无法加载凭据分组: \(error.localizedDescription)"
                }
            }
        }
    }

    func addServer(_ input: ServerInput) {
        Task {
            do {
                let server = try bridge.addServer(input: input)
                await MainActor.run { servers.append(server) }
            } catch {
                await MainActor.run {
                    alertTitle = "添加失败"
                    alertMessage = "无法添加服务器: \(error.localizedDescription)"
                }
            }
        }
    }

    func updateServer(id: String, input: ServerInput) {
        Task {
            do {
                let server = try bridge.updateServer(id: id, input: input)
                await MainActor.run { servers = servers.map { $0.id == id ? server : $0 } }
            } catch {
                await MainActor.run {
                    alertTitle = "更新失败"
                    alertMessage = "无法更新服务器: \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteServer(_ id: String) {
        Task {
            do {
                try bridge.deleteServer(id: id)
                await MainActor.run {
                    let tabsToRemove = tabs.filter { $0.serverId == id }
                    let dockerTabIdsToRemove = Set(tabsToRemove.filter { $0.type == .docker }.map(\.id))
                    for tab in tabsToRemove {
                        disconnectAllChannels(tab: tab)
                    }
                    servers.removeAll { $0.id == id }
                    tabs.removeAll { $0.serverId == id }
                    for tabId in dockerTabIdsToRemove {
                        dockerPanelSnapshots.removeValue(forKey: tabId)
                    }
                    if let active = activeTabId, !tabs.contains(where: { $0.id == active }) {
                        closeSessionScopedTools()
                        activeTabId = tabs.last?.id
                    }
                }
            } catch {
                await MainActor.run {
                    alertTitle = "删除失败"
                    alertMessage = "无法删除服务器: \(error.localizedDescription)"
                }
            }
        }
    }

    func addCg(_ input: CredentialGroupInput) {
        Task {
            do {
                let cg = try bridge.addCredentialGroup(input: input)
                await MainActor.run { credentialGroups.append(cg) }
            } catch {
                await MainActor.run {
                    alertTitle = "添加失败"
                    alertMessage = "无法添加凭据分组: \(error.localizedDescription)"
                }
            }
        }
    }

    func updateCg(id: String, input: CredentialGroupInput) {
        Task {
            do {
                let cg = try bridge.updateCredentialGroup(id: id, input: input)
                await MainActor.run { credentialGroups = credentialGroups.map { $0.id == id ? cg : $0 } }
            } catch {
                await MainActor.run {
                    alertTitle = "更新失败"
                    alertMessage = "无法更新凭据分组: \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteCg(_ id: String) {
        Task {
            do {
                try bridge.deleteCredentialGroup(id: id)
                await MainActor.run { credentialGroups.removeAll { $0.id == id } }
            } catch {
                await MainActor.run {
                    alertTitle = "删除失败"
                    alertMessage = "无法删除凭据分组: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadDatabaseConnections() {
        Task {
            do {
                let result = try await bridge.listDatabaseConnectionsAsync()
                await MainActor.run { self.databaseConnections = result }
            } catch {
                await MainActor.run {
                    alertTitle = "加载失败"
                    alertMessage = "无法加载数据库连接: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadDatabaseBackupRecords() {
        Task {
            do {
                let result = try await bridge.listDatabaseBackupRecordsAsync()
                await MainActor.run { self.databaseBackupRecords = result }
            } catch {
                await MainActor.run {
                    alertTitle = "加载失败"
                    alertMessage = "无法加载数据库备份记录: \(error.localizedDescription)"
                }
            }
        }
    }

    func addDatabaseConnection(_ input: DatabaseConnectionInput) {
        Task {
            await MainActor.run { databaseOperationLoading = true }
            do {
                let connection = try await bridge.addDatabaseConnectionAsync(input: input)
                await MainActor.run {
                    databaseConnections.append(connection)
                    databaseOperationLoading = false
                }
            } catch {
                await MainActor.run {
                    databaseOperationLoading = false
                    alertTitle = "添加失败"
                    alertMessage = "无法添加数据库连接: \(error.localizedDescription)"
                }
            }
        }
    }

    func updateDatabaseConnection(id: String, input: DatabaseConnectionInput) {
        Task {
            await MainActor.run { databaseOperationLoading = true }
            do {
                let connection = try await bridge.updateDatabaseConnectionAsync(id: id, input: input)
                await MainActor.run {
                    databaseConnections = databaseConnections.map { $0.id == id ? connection : $0 }
                    if editingDatabaseConnection?.id == id {
                        editingDatabaseConnection = connection
                    }
                    tabs = tabs.map { tab in
                        guard tab.type == .database, tab.serverId == id else { return tab }
                        var updated = tab
                        updated.serverName = connection.name
                        updated.title = "DB: \(connection.name)"
                        return updated
                    }
                    invalidateDatabasePanels(forConnectionId: id)
                    databaseOperationLoading = false
                }
            } catch {
                await MainActor.run {
                    databaseOperationLoading = false
                    alertTitle = "更新失败"
                    alertMessage = "无法更新数据库连接: \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteDatabaseConnection(_ id: String) {
        Task {
            await MainActor.run { databaseOperationLoading = true }
            do {
                try await bridge.deleteDatabaseConnectionAsync(id: id)
                await MainActor.run {
                    let removedTabIds = tabs.filter { $0.type == .database && $0.serverId == id }.map(\.id)
                    databaseConnections.removeAll { $0.id == id }
                    if editingDatabaseConnection?.id == id {
                        editingDatabaseConnection = nil
                    }
                    invalidateDatabasePanels(forConnectionId: id)
                    tabs.removeAll { $0.type == .database && $0.serverId == id }
                    if let active = activeTabId, removedTabIds.contains(active) {
                        closeSessionScopedTools()
                        activeTabId = tabs.last?.id
                    }
                    databaseOperationLoading = false
                }
            } catch {
                await MainActor.run {
                    databaseOperationLoading = false
                    alertTitle = "删除失败"
                    alertMessage = "无法删除数据库连接: \(error.localizedDescription)"
                }
            }
        }
    }

    func openDatabaseConnectionDialog(_ connection: DatabaseConnection? = nil) {
        editingDatabaseConnection = connection
        databaseConnectionDialogOpen = true
    }

    func closeDatabaseConnectionDialog() {
        databaseConnectionDialogOpen = false
        editingDatabaseConnection = nil
    }

    func saveDatabaseConnectionFromDialog(_ input: DatabaseConnectionInput) {
        let editingId = editingDatabaseConnection?.id
        Task {
            await MainActor.run { databaseOperationLoading = true }
            do {
                if let editingId {
                    let connection = try await bridge.updateDatabaseConnectionAsync(id: editingId, input: input)
                    await MainActor.run {
                        databaseConnections = databaseConnections.map { $0.id == editingId ? connection : $0 }
                        tabs = tabs.map { tab in
                            guard tab.type == .database, tab.serverId == editingId else { return tab }
                            var updated = tab
                            updated.serverName = connection.name
                            updated.title = "DB: \(connection.name)"
                            return updated
                        }
                        invalidateDatabasePanels(forConnectionId: editingId)
                        databaseOperationLoading = false
                        closeDatabaseConnectionDialog()
                    }
                } else {
                    let connection = try await bridge.addDatabaseConnectionAsync(input: input)
                    await MainActor.run {
                        databaseConnections.append(connection)
                        databaseOperationLoading = false
                        closeDatabaseConnectionDialog()
                    }
                }
            } catch {
                await MainActor.run {
                    databaseOperationLoading = false
                    alertTitle = editingId == nil ? "添加失败" : "更新失败"
                    alertMessage = "无法保存数据库连接: \(error.localizedDescription)"
                }
            }
        }
    }

    func openDatabaseConnection(_ connection: DatabaseConnection) {
        if let existing = tabs.first(where: { $0.type == .database && $0.serverId == connection.id }) {
            requestActivateTab(existing.id)
            return
        }
        let id = "database-\(connection.id)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let tab = TabItem(
            id: id,
            type: .database,
            serverId: connection.id,
            serverName: connection.name,
            title: "DB: \(connection.name)"
        )
        tabs.append(tab)
        requestActivateTab(id)
    }

    func testDatabaseConnection(_ connection: DatabaseConnection) {
        Task {
            await MainActor.run { databaseOperationLoading = true }
            do {
                let result = try await bridge.testDatabaseConnectionAsync(id: connection.id, installSqlite: false)
                if shouldPromptForRemoteSqliteInstall(connection: connection, result: result) {
                    let confirmed = await MainActor.run {
                        databaseOperationLoading = false
                        return confirmRemoteSqliteInstall(message: result.message)
                    }
                    guard confirmed else {
                        await MainActor.run {
                            alertTitle = "连接测试失败"
                            alertMessage = result.message
                        }
                        return
                    }
                    await MainActor.run { databaseOperationLoading = true }
                    let installResult = try await bridge.testDatabaseConnectionAsync(id: connection.id, installSqlite: true)
                    await MainActor.run {
                        databaseOperationLoading = false
                        alertTitle = installResult.ok ? "连接测试成功" : "连接测试失败"
                        alertMessage = installResult.message
                    }
                    return
                }
                await MainActor.run {
                    databaseOperationLoading = false
                    alertTitle = result.ok ? "连接测试成功" : "连接测试失败"
                    alertMessage = result.message
                }
            } catch {
                await MainActor.run {
                    databaseOperationLoading = false
                    alertTitle = "连接测试失败"
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func shouldPromptForRemoteSqliteInstall(connection: DatabaseConnection, result: DatabaseOperationResult) -> Bool {
        connection.engine == "remote_sqlite"
            && result.code == "sqlite_missing"
            && result.message.contains("Suggested command:")
    }

    @MainActor
    private func confirmRemoteSqliteInstall(message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "远端缺少 sqlite3"
        alert.informativeText = "\(message)\n\n是否在远端服务器执行上述安装命令？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "安装并重新测试")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func backupDatabaseConnection(_ connection: DatabaseConnection) {
        Task {
            do {
                let result = try await backupDatabaseConnectionResult(connection)
                await MainActor.run {
                    alertTitle = result.ok ? "备份完成" : "备份失败"
                    alertMessage = databaseOperationMessage(result)
                }
            } catch {
                await MainActor.run {
                    alertTitle = "备份失败"
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    func backupDatabaseConnectionResult(_ connection: DatabaseConnection) async throws -> DatabaseOperationResult {
        databaseOperationLoading = true
        defer { databaseOperationLoading = false }
        let result = try await bridge.backupDatabaseAsync(connectionId: connection.id)
        if let records = try? await bridge.listDatabaseBackupRecordsAsync() {
            databaseBackupRecords = records
        }
        return result
    }

    @MainActor
    func restoreDatabaseBackup(request: DatabaseRestoreRequest) async throws -> DatabaseOperationResult {
        databaseOperationLoading = true
        defer { databaseOperationLoading = false }
        let result = try await bridge.restoreDatabaseAsync(request: request)
        if let records = try? await bridge.listDatabaseBackupRecordsAsync() {
            databaseBackupRecords = records
        }
        invalidateDatabasePanels(forConnectionId: request.target_connection_id)
        return result
    }

    @MainActor
    func prepareDatabaseImport(backupPath: String, targetConnectionId: String, mode: String) async throws -> DatabaseImportPlan {
        databaseOperationLoading = true
        defer { databaseOperationLoading = false }
        return try await bridge.prepareDatabaseImportAsync(
            backupPath: backupPath,
            targetConnectionId: targetConnectionId,
            mode: mode
        )
    }

    @MainActor
    func runDatabaseImport(request: DatabaseImportRequest) async throws -> DatabaseOperationResult {
        databaseOperationLoading = true
        defer { databaseOperationLoading = false }
        let result = try await bridge.runDatabaseImportAsync(request: request)
        if let records = try? await bridge.listDatabaseBackupRecordsAsync() {
            databaseBackupRecords = records
        }
        invalidateDatabasePanels(forConnectionId: request.plan.target_connection_id)
        return result
    }

    func databaseOperationMessage(_ result: DatabaseOperationResult) -> String {
        var parts = [result.message]
        if let artifactPath = result.artifact_path, !artifactPath.isEmpty {
            parts.append("路径: \(artifactPath)")
        }
        if let affectedRows = result.affected_rows {
            parts.append("行数: \(affectedRows)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func addLocalTerminalTab() {
        let id = "local-\(Int(Date().timeIntervalSince1970 * 1000))"
        let tab = TabItem(
            id: id,
            type: .terminal,
            serverId: nil,
            connectionTarget: .local,
            serverName: "本地",
            title: "本地终端"
        )
        tabs.append(tab)
        requestActivateTab(id)
    }

    @discardableResult
    func addTemporaryTerminalTab(
        draft: TemporaryConnectionDraft,
        sessionId: String? = nil
    ) -> String {
        let id = "temporary-\(UUID().uuidString)"
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? draft.host : name
        let tab = TabItem(
            id: id,
            type: .terminal,
            serverId: nil,
            connectionTarget: .temporary(tabId: id),
            serverName: displayName,
            title: "SSH: \(displayName)",
            sessionId: sessionId,
            focusedChannelId: sessionId
        )
        tabState.temporaryDrafts[id] = draft
        tabState.temporaryTabTokens[id] = UUID()
        tabs.append(tab)
        requestActivateTab(id)
        return id
    }

    func temporaryDraft(for tabId: String) -> TemporaryConnectionDraft? {
        tabState.temporaryDrafts[tabId]
    }

    func temporaryPromotionFailure(for tabId: String) -> TemporaryPromotionFailure? {
        tabState.temporaryPromotionFailures[tabId]
    }

    @MainActor
    @discardableResult
    func promoteTemporaryTab(
        tabId: String,
        sessionId: String
    ) async throws -> TemporaryPromotionOutcome {
        guard !tabState.temporaryPromotionTabIds.contains(tabId) else {
            throw WorkspaceError.promotionInProgress
        }
        guard let draft = temporaryDraft(for: tabId),
              let tabToken = tabState.temporaryTabTokens[tabId],
              let tab = tabState.tab(id: tabId),
              tab.connectionTarget == .temporary(tabId: tabId) else {
            throw WorkspaceError.missingTemporaryDraft
        }
        guard tab.sessionId == sessionId else {
            throw WorkspaceError.staleTemporarySession
        }

        tabState.temporaryPromotionTabIds.insert(tabId)
        defer { tabState.temporaryPromotionTabIds.remove(tabId) }

        let server = try await workspaceBridge.promoteTemporaryServerAsync(
            sessionId: sessionId,
            input: draft.promotionInput
        )

        refreshServerInventory(with: server)

        guard tabState.temporaryTabTokens[tabId] == tabToken else {
            return .persistedAfterTabClosed(serverId: server.id)
        }
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabId }),
              tabs[tabIndex].connectionTarget == .temporary(tabId: tabId),
              tabs[tabIndex].sessionId == sessionId,
              temporaryDraft(for: tabId) == draft else {
            return .persistedWithoutRebinding(serverId: server.id)
        }
        tabs[tabIndex].serverId = server.id
        tabs[tabIndex].connectionTarget = .saved(serverId: server.id)
        tabs[tabIndex].serverName = server.name
        tabs[tabIndex].title = "SSH: \(server.name)"
        clearTemporaryDraft(tabId: tabId)
        return .promoted(serverId: server.id)
    }

    @MainActor
    func retryTemporaryPromotion(tabId: String) async {
        guard var failure = temporaryPromotionFailure(for: tabId),
              !failure.isRetrying,
              let tab = tabState.tab(id: tabId),
              tab.connectionTarget == .temporary(tabId: tabId),
              tab.sessionId == failure.sessionId,
              temporaryDraft(for: tabId) != nil else {
            return
        }

        failure.isRetrying = true
        tabState.temporaryPromotionFailures[tabId] = failure
        do {
            let outcome = try await promoteTemporaryTab(
                tabId: tabId,
                sessionId: failure.sessionId
            )
            switch outcome {
            case .promoted:
                tabState.temporaryPromotionFailures.removeValue(forKey: tabId)
            case .persistedAfterTabClosed:
                tabState.temporaryPromotionFailures.removeValue(forKey: tabId)
            case .persistedWithoutRebinding:
                tabState.temporaryPromotionFailures.removeValue(forKey: tabId)
            }
        } catch {
            recordTemporaryPromotionFailure(
                error,
                tabId: tabId,
                sessionId: failure.sessionId
            )
        }
    }

    func dismissTemporaryPromotionFailure(tabId: String) {
        tabState.temporaryPromotionFailures.removeValue(forKey: tabId)
    }

    private func refreshServerInventory(with server: Server) {
        if let serverIndex = servers.firstIndex(where: { $0.id == server.id }) {
            servers[serverIndex] = server
        } else {
            servers.append(server)
        }
        loadServers()
        loadServerOrganization()
    }

    func focusServerQuickConnect() {
        guard uiState.temporaryConnectionDraft == nil else { return }
        uiState.serverQuickConnectInputFocused = true
        uiState.serverQuickConnectResultsVisible = !uiState.serverQuickConnectQuery.isEmpty
    }

    func closeServerQuickConnect(clearQuery: Bool = true) {
        uiState.serverQuickConnectResultsVisible = false
        uiState.serverQuickConnectInputFocused = false
        if clearQuery {
            uiState.serverQuickConnectQuery = ""
        }
        restoreActiveTerminalFocus()
    }

    func presentTemporaryConnectionPanel(address: ParsedServerAddress) {
        uiState.temporaryConnectionToken = UUID()
        uiState.temporaryConnectionDraft = TemporaryConnectionDraft(
            host: address.host,
            port: address.port,
            username: address.username ?? "",
            authType: "password"
        )
        uiState.serverQuickConnectResultsVisible = false
        uiState.serverQuickConnectInputFocused = false
    }

    func dismissTemporaryConnectionPanel(returnToSearch: Bool = true) {
        uiState.temporaryConnectionToken = nil
        if var draft = uiState.temporaryConnectionDraft {
            draft.clearSecrets()
            uiState.temporaryConnectionDraft = draft
        }
        uiState.temporaryConnectionDraft = nil
        uiState.serverQuickConnectResultsVisible = returnToSearch
            && !uiState.serverQuickConnectQuery.isEmpty
        uiState.serverQuickConnectInputFocused = returnToSearch
        if !returnToSearch {
            uiState.serverQuickConnectQuery = ""
            restoreActiveTerminalFocus()
        }
    }

    @MainActor
    @discardableResult
    func submitTemporaryConnection() -> Task<Void, Never>? {
        guard let token = uiState.temporaryConnectionToken,
              var draft = uiState.temporaryConnectionDraft,
              !draft.isConnecting else { return nil }

        if let validationError = temporaryConnectionValidationError(draft) {
            draft.validationError = validationError
            draft.connectionError = nil
            uiState.temporaryConnectionDraft = draft
            return nil
        }

        draft.validationError = nil
        draft.connectionError = nil
        draft.isConnecting = true
        uiState.temporaryConnectionDraft = draft
        let submittedDraft = draft

        return Task {
            do {
                let sessionId = try await workspaceBridge.connectTemporarySSHAsync(
                    input: submittedDraft.connectionInput
                )
                guard uiState.temporaryConnectionToken == token,
                      uiState.temporaryConnectionDraft != nil else {
                    await discardSSHSession(sessionId)
                    return
                }

                var tabDraft = submittedDraft
                tabDraft.isConnecting = false
                tabDraft.validationError = nil
                tabDraft.connectionError = nil
                let tabId = addTemporaryTerminalTab(
                    draft: tabDraft,
                    sessionId: sessionId
                )
                dismissTemporaryConnectionPanel(returnToSearch: false)
                restoreActiveTerminalFocus()

                if tabDraft.saveToAssets {
                    do {
                        _ = try await promoteTemporaryTab(
                            tabId: tabId,
                            sessionId: sessionId
                        )
                    } catch {
                        recordTemporaryPromotionFailure(
                            error,
                            tabId: tabId,
                            sessionId: sessionId
                        )
                    }
                }

            } catch {
                guard uiState.temporaryConnectionToken == token,
                      var currentDraft = uiState.temporaryConnectionDraft else { return }
                currentDraft.isConnecting = false
                currentDraft.connectionError = error.localizedDescription
                uiState.temporaryConnectionDraft = currentDraft
            }
        }
    }

    @MainActor
    private func recordTemporaryPromotionFailure(
        _ error: Error,
        tabId: String,
        sessionId: String
    ) {
        guard let tab = tabState.tab(id: tabId),
              tab.connectionTarget == .temporary(tabId: tabId),
              tab.sessionId == sessionId,
              temporaryDraft(for: tabId) != nil else {
            tabState.temporaryPromotionFailures.removeValue(forKey: tabId)
            return
        }
        tabState.temporaryPromotionFailures[tabId] = TemporaryPromotionFailure(
            sessionId: sessionId,
            message: "服务器已连接，但保存失败: \(error.localizedDescription)"
        )
    }

    @discardableResult
    func handleEscape() -> Bool {
        if uiState.temporaryConnectionDraft != nil {
            dismissTemporaryConnectionPanel()
            return true
        }
        if uiState.serverQuickConnectResultsVisible {
            uiState.serverQuickConnectResultsVisible = false
            return true
        }
        if uiState.serverQuickConnectInputFocused {
            uiState.serverQuickConnectInputFocused = false
            restoreActiveTerminalFocus()
            return true
        }
        return false
    }

    func restoreActiveTerminalFocus() {
        guard let activeTabId,
              let tab = tabs.first(where: { $0.id == activeTabId }),
              tab.type == .terminal,
              let sessionId = tab.focusedChannelId ?? tab.sessionId,
              let terminalView = OrbitBridge.shared.terminalView(for: sessionId) as? OrbitTerminalView else {
            return
        }
        terminalView.window?.makeFirstResponder(terminalView)
    }

    private func temporaryConnectionValidationError(_ draft: TemporaryConnectionDraft) -> String? {
        if draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入主机地址"
        }
        if draft.port == 0 {
            return "端口必须在 1 到 65535 之间"
        }
        if draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入用户名"
        }
        if draft.credentialGroupId == nil {
            if draft.authType == "password",
               draft.password.isEmpty {
                return "请输入密码"
            }
            if draft.authType == "key" {
                if draft.keySource == "file", draft.keyFilePath.isEmpty {
                    return "请选择私钥文件"
                }
                if draft.keySource != "file", draft.privateKey.isEmpty {
                    return "请输入私钥内容"
                }
            }
        }
        if draft.saveToAssets,
           draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入服务器名称"
        }
        return nil
    }

    func addTab(server: Server, type: TabType) {
        if type == .monitor || type == .docker {
            if let existing = tabs.first(where: { $0.type == type && $0.serverId == server.id }) {
                requestActivateTab(existing.id)
                return
            }
        }
        let id = "\(type.rawValue)-\(server.id)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let titles: [TabType: String] = [
            .terminal: "SSH: \(server.name)",
            .sftp: "SFTP: \(server.name)",
            .monitor: "Monitor: \(server.name)",
            .docker: "Docker: \(server.name)",
            .database: "Database: \(server.name)",
        ]
        var tab = TabItem(id: id, type: type, serverId: server.id, serverName: server.name, title: titles[type] ?? "")
        if type == .terminal {
            tab.paneTree = nil
        }
        tabs.append(tab)
        trackRecentServer(server.id)
        requestActivateTab(id)
    }

    func addTerminalTab(server: Server, title: String? = nil, initialCommand: String? = nil) {
        let id = "terminal-\(server.id)-\(Int(Date().timeIntervalSince1970 * 1000))"
        var tab = TabItem(
            id: id,
            type: .terminal,
            serverId: server.id,
            serverName: server.name,
            title: title ?? "SSH: \(server.name)",
            initialCommand: initialCommand
        )
        tab.paneTree = nil
        tabs.append(tab)
        trackRecentServer(server.id)
        requestActivateTab(id)
    }

    func consumeInitialCommand(tabId: String) -> String? {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        let command = tabs[idx].initialCommand
        tabs[idx].initialCommand = nil
        return command
    }

    @discardableResult
    func requestActivateTab(_ tabId: String) -> Bool {
        guard tabId != activeTabId else { return true }
        if let currentTabId = activeTabId,
           activeSftpTransferTabIds.contains(currentTabId) {
            pendingContextSwitchTabId = tabId
            pendingContextSwitchMessage = "当前 SFTP 传输仍在进行。切换会关闭当前会话工具，确认要切换吗？"
            return false
        }
        activateTab(tabId)
        return true
    }

    private func activateTab(_ tabId: String) {
        closeSessionScopedTools()
        activeTabId = tabId
    }

    func confirmPendingContextSwitch() {
        guard let tabId = pendingContextSwitchTabId else { return }
        pendingContextSwitchTabId = nil
        pendingContextSwitchMessage = nil
        activateTab(tabId)
    }

    func cancelPendingContextSwitch() {
        pendingContextSwitchTabId = nil
        pendingContextSwitchMessage = nil
    }

    func requestFocusPane(tabId: String, paneId: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        if tabs[idx].focusedChannelId != paneId {
            closeSessionScopedTools()
        }
        tabs[idx].focusedChannelId = paneId
    }

    func closeSessionScopedTools() {
        if let pending = aiPendingConfirmation {
            appendAuditEvent(
                category: .aiAction,
                action: "command_confirmation",
                target: pending.command,
                result: .canceled,
                summary: "会话上下文切换，已取消待确认的 AI 命令"
            )
        }
        aiPendingConfirmation = nil
        activeTool = nil
        if aiPanelOpen {
            aiPanelOpen = false
        }
    }

    func setSftpTransferActive(_ active: Bool, for tabId: String) {
        if active {
            activeSftpTransferTabIds.insert(tabId)
        } else {
            activeSftpTransferTabIds.remove(tabId)
        }
    }

    func updateDatabaseAIContext(tabId: String, selectedTable: String?, sqlText: String, resultSummary: String) {
        databaseAIContexts[tabId] = DatabaseAIContext(
            selectedTable: selectedTable,
            sqlText: sqlText,
            resultSummary: resultSummary
        )
    }

    func saveDockerPanelSnapshot(_ snapshot: DockerPanelSnapshot, for tabId: String) {
        dockerPanelSnapshots[tabId] = snapshot
    }

    func dockerPanelSnapshot(for tabId: String) -> DockerPanelSnapshot? {
        dockerPanelSnapshots[tabId]
    }

    func saveDatabasePanelSnapshot(_ snapshot: DatabasePanelSnapshot, for tabId: String) {
        databasePanelSnapshots[tabId] = snapshot
    }

    func databasePanelSnapshot(for tabId: String) -> DatabasePanelSnapshot? {
        databasePanelSnapshots[tabId]
    }

    func removeDatabasePanelSnapshot(for tabId: String) {
        databasePanelSnapshots.removeValue(forKey: tabId)
    }

    func databasePanelInvalidationToken(for tabId: String) -> Int {
        databasePanelInvalidationTokens[tabId, default: 0]
    }

    private func invalidateDatabasePanels(forConnectionId connectionId: String) {
        let affectedTabIds = tabs
            .filter { $0.type == .database && $0.serverId == connectionId }
            .map(\.id)
        for tabId in affectedTabIds {
            databasePanelSnapshots.removeValue(forKey: tabId)
            databaseAIContexts.removeValue(forKey: tabId)
            var tokens = databasePanelInvalidationTokens
            tokens[tabId, default: 0] += 1
            databasePanelInvalidationTokens = tokens
        }
    }

    func openTool(_ tool: SessionTool, presentation: ToolPresentation = .floating) {
        let context = activeSessionContext
        guard canOpenTool(tool, in: context) == nil else { return }

        if tool == .ai {
            activeTool = BoundToolState(tool: tool, presentation: .pinned, boundContext: context)
            aiPanelOpen = true
            return
        }

        activeTool = BoundToolState(tool: tool, presentation: presentation, boundContext: context)
    }

    func closeOverlayTool() {
        if activeTool?.tool != .ai {
            activeTool = nil
        }
    }

    func toggleAIDrawerForCurrentContext() {
        if aiPanelOpen {
            aiPanelOpen = false
            if activeTool?.tool == .ai {
                activeTool = nil
            }
        } else {
            openTool(.ai, presentation: .pinned)
        }
    }

    func canOpenTool(_ tool: SessionTool, in context: ActiveSessionContext? = nil) -> String? {
        let context = context ?? activeSessionContext
        if context.kind == .none {
            return "当前没有活动会话"
        }
        if tool == .sftp || tool == .monitor {
            if context.kind != .terminal || context.sessionId == nil || context.connectionStatus != .connected {
                return tool == .sftp ? "SSH 连接建立后可用 SFTP" : "SSH 连接建立后可用监控"
            }
        }
        if tool == .snippets {
            if (context.kind == .terminal || context.kind == .localShell) && context.sessionId == nil {
                return "终端会话建立后可插入片段"
            }
        }
        if tool == .ai {
            if (context.kind == .terminal || context.kind == .localShell) && context.sessionId == nil {
                return "终端会话建立后可使用 AI"
            }
        }
        if !context.capabilities.contains(capability(for: tool)) {
            return disabledReason(for: tool, context: context)
        }
        return nil
    }

    var canUsePersistedServerTools: Bool {
        guard let activeTab = tabState.activeTab else { return false }
        if case .saved = activeTab.connectionTarget {
            return true
        }
        return false
    }

    private func capability(for tool: SessionTool) -> SessionCapabilities {
        switch tool {
        case .ai: return .ai
        case .sftp: return .sftp
        case .monitor: return .monitor
        case .logs: return .logs
        case .snippets: return .snippets
        }
    }

    private func disabledReason(for tool: SessionTool, context: ActiveSessionContext) -> String {
        switch tool {
        case .sftp:
            return context.kind == .localShell ? "本地终端不支持 SFTP" : "当前会话不支持 SFTP"
        case .monitor:
            return context.kind == .localShell ? "本地终端不支持远端监控" : "当前会话不支持监控"
        default:
            return "当前会话不支持该工具"
        }
    }

    func appendAuditEvent(category: AuditCategory, action: String, target: String? = nil, result: AuditResult, summary: String) {
        let context = activeSessionContext
        let event = AuditEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            contextId: context.identity,
            tabId: context.tabId,
            sessionId: context.sessionId,
            serverId: context.serverId,
            category: category,
            action: action,
            target: target,
            result: result,
            summary: summary
        )
        auditEventsByContext[context.identity, default: []].append(event)
    }

    func auditEvents(for context: ActiveSessionContext) -> [AuditEvent] {
        auditEventsByContext[context.identity] ?? []
    }

    func splitCurrentPane(direction: SplitDirection) {
        guard let active = activeTabId,
              let tabIdx = tabs.firstIndex(where: { $0.id == active }),
              tabs[tabIdx].type == .terminal else { return }

        let tab = tabs[tabIdx]
        let existingChannelId: String
        if let focused = tab.focusedChannelId {
            existingChannelId = focused
        } else if let sid = tab.sessionId {
            existingChannelId = sid
        } else {
            return
        }

        let tabId = tab.id
        Task {
            let newChannelId: String
            do {
                newChannelId = try await workspaceBridge.spawnChannelAsync(
                    existingSessionId: existingChannelId
                )
            } catch {
                await MainActor.run {
                    alertTitle = "分屏失败"
                    alertMessage = "无法创建新通道: \(error.localizedDescription)"
                }
                return
            }

            let attached = await MainActor.run {
                guard let idx = tabs.firstIndex(where: { $0.id == tabId }),
                      tabOwnsChannel(tabs[idx], channelId: existingChannelId) else {
                    return false
                }
                let newSplitId = UUID().uuidString
                let newLeaf = PaneNode.leaf(channelId: newChannelId)

                if let tree = tabs[idx].paneTree {
                    tabs[idx].paneTree = tree.replacingLeaf(channelId: existingChannelId, with:
                        .split(id: newSplitId, direction: direction, ratio: 0.5,
                               first: .leaf(channelId: existingChannelId), second: newLeaf))
                } else {
                    tabs[idx].paneTree = .split(id: newSplitId, direction: direction, ratio: 0.5,
                                                 first: .leaf(channelId: existingChannelId), second: newLeaf)
                }
                requestFocusPane(tabId: tabId, paneId: newChannelId)
                return true
            }

            guard attached else {
                await discardSSHSession(newChannelId)
                return
            }

            // Focus the new terminal after SwiftUI creates it
            let cid = newChannelId
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if let tv = OrbitBridge.shared.terminalView(for: cid) as? OrbitTerminalView {
                    tv.window?.makeFirstResponder(tv)
                }
            }
        }
    }

    private func tabOwnsChannel(_ tab: TabItem, channelId: String) -> Bool {
        if let tree = tab.paneTree {
            return tree.contains(channelId)
        }
        return tab.sessionId == channelId
    }

    func closeCurrentPane() {
        guard let active = activeTabId,
              let tabIdx = tabs.firstIndex(where: { $0.id == active }) else { return }

        let tab = tabs[tabIdx]
        guard let tree = tab.paneTree,
              let focused = tab.focusedChannelId ?? tab.sessionId else {
            removeTab(active)
            return
        }

        bridge.removeSSHHandlers(sessionId: focused)
        bridge.removeTerminalView(sessionId: focused)
        Task { try? await bridge.disconnectSSHAsync(sessionId: focused) }

        if let newTree = tree.removing(channelId: focused) {
            if case .leaf(let remaining) = newTree {
                tabs[tabIdx].paneTree = nil
                if tabs[tabIdx].focusedChannelId != nil {
                    closeSessionScopedTools()
                }
                tabs[tabIdx].focusedChannelId = nil
                if tabs[tabIdx].sessionId == focused {
                    tabs[tabIdx].sessionId = remaining
                }
            } else {
                tabs[tabIdx].paneTree = newTree
                if tabs[tabIdx].focusedChannelId != newTree.channelIds.first {
                    closeSessionScopedTools()
                }
                tabs[tabIdx].focusedChannelId = newTree.channelIds.first
                if tabs[tabIdx].sessionId == focused {
                    tabs[tabIdx].sessionId = newTree.channelIds.first
                }
            }
        } else {
            removeTab(active)
        }
    }

    func navigatePane(forward: Bool) {
        guard let active = activeTabId,
              let tabIdx = tabs.firstIndex(where: { $0.id == active }),
              let tree = tabs[tabIdx].paneTree,
              let focused = tabs[tabIdx].focusedChannelId ?? tabs[tabIdx].sessionId,
              let next = tree.findAdjacent(channelId: focused, forward: forward) else { return }
        requestFocusPane(tabId: active, paneId: next)
        if let tv = OrbitBridge.shared.terminalView(for: next) as? OrbitTerminalView {
            tv.window?.makeFirstResponder(tv)
        }
    }

    func resizePane(grow: Bool) {
        guard let active = activeTabId,
              let tabIdx = tabs.firstIndex(where: { $0.id == active }),
              let tree = tabs[tabIdx].paneTree,
              let focused = tabs[tabIdx].focusedChannelId ?? tabs[tabIdx].sessionId else { return }
        let delta: Double = grow ? 0.05 : -0.05
        tabs[tabIdx].paneTree = tree.adjusting(channelId: focused, delta: delta)
    }

    func updatePaneRatio(tabId: String, splitId: String, newRatio: Double) {
        guard let tabIdx = tabs.firstIndex(where: { $0.id == tabId }),
              let tree = tabs[tabIdx].paneTree else { return }
        tabs[tabIdx].paneTree = tree.updateRatio(splitId: splitId, newRatio: newRatio)
    }

    private func disconnectAllChannels(tab: TabItem) {
        let channelIds: [String]
        if let tree = tab.paneTree {
            channelIds = tree.channelIds
        } else if let sid = tab.sessionId {
            channelIds = [sid]
        } else {
            channelIds = []
        }
        for channelId in channelIds {
            bridge.removeSSHHandlers(sessionId: channelId)
            bridge.removeTerminalView(sessionId: channelId)
        }
        Task.detached {
            for channelId in channelIds {
                try? self.bridge.disconnectSSH(sessionId: channelId)
            }
        }
    }

    func removeTab(_ id: String) {
        performRemoveTab(id)
    }

    var pendingCloseTab: TabItem? {
        guard let pendingCloseTabId else { return nil }
        return tabs.first(where: { $0.id == pendingCloseTabId })
    }

    func requestCloseTab(_ tab: TabItem) {
        if tab.type == .terminal, tab.sessionId != nil {
            pendingCloseTabId = tab.id
        } else {
            performRemoveTab(tab.id)
        }
    }

    func confirmCloseTab() {
        guard let tabId = pendingCloseTabId else { return }
        pendingCloseTabId = nil
        performRemoveTab(tabId)
    }

    func cancelCloseTab() {
        pendingCloseTabId = nil
    }

    func confirmQuit() {
        if let tabId = pendingQuitTabId {
            performRemoveTab(tabId)
        }
        pendingQuitTabId = nil
        showQuitConfirmation = false
        NSApp.terminate(nil)
    }

    func cancelQuit() {
        pendingQuitTabId = nil
        showQuitConfirmation = false
    }

    private func performRemoveTab(_ id: String) {
        let removedIndex = tabs.firstIndex(where: { $0.id == id }) ?? 0
        if let tab = tabs.first(where: { $0.id == id }) {
            disconnectAllChannels(tab: tab)
        }
        dockerPanelSnapshots.removeValue(forKey: id)
        databasePanelSnapshots.removeValue(forKey: id)
        clearTemporaryDraft(tabId: id)
        tabs.removeAll { $0.id == id }
        if activeTabId == id {
            closeSessionScopedTools()
            activeTabId = tabs.isEmpty ? nil : tabs[min(removedIndex, tabs.count - 1)].id
        }
    }

    func updateTabSessionId(_ tabId: String, sessionId: String) {
        if let idx = tabs.firstIndex(where: { $0.id == tabId }) {
            tabs[idx].sessionId = sessionId
            if tabs[idx].focusedChannelId == nil {
                if tabs[idx].id == activeTabId {
                    closeSessionScopedTools()
                }
                tabs[idx].focusedChannelId = sessionId
            }
        }
    }

    @MainActor
    @discardableResult
    func installSSHSession(
        tabId: String,
        expectedTarget: ServerConnectionTarget,
        sessionId: String,
        dataHandler: @escaping (Data) -> Void,
        closedHandler: @escaping () -> Void
    ) async -> Bool {
        guard let tab = tabState.tab(id: tabId),
              tab.type == .terminal,
              tab.connectionTarget == expectedTarget,
              tab.sessionId == nil else {
            await discardSSHSession(sessionId)
            return false
        }
        updateTabSessionId(tabId, sessionId: sessionId)
        bridge.setSSHHandlers(
            sessionId: sessionId,
            dataHandler: dataHandler,
            closedHandler: closedHandler
        )
        let installed = tabState.tab(id: tabId)?.connectionTarget == expectedTarget
            && tabState.tab(id: tabId)?.sessionId == sessionId
        if !installed {
            await discardSSHSession(sessionId)
        }
        return installed
    }

    @MainActor
    private func discardSSHSession(_ sessionId: String) async {
        bridge.removeSSHHandlers(sessionId: sessionId)
        bridge.removeTerminalView(sessionId: sessionId)
        try? await workspaceBridge.disconnectSSHAsync(sessionId: sessionId)
    }

    func connectSSH(for connectionTarget: ServerConnectionTarget) async throws -> String {
        switch connectionTarget {
        case .saved(let serverId):
            return try await bridge.connectSSHAsync(serverId: serverId)
        case .temporary(let tabId):
            guard let draft = temporaryDraft(for: tabId) else {
                throw WorkspaceError.missingTemporaryDraft
            }
            return try await workspaceBridge.connectTemporarySSHAsync(input: draft.connectionInput)
        case .local:
            throw WorkspaceError.localConnectionHandledSeparately
        }
    }

    func connectSSH(tabId: String, serverId: String) {
        Task {
            do {
                let sessionId = try await bridge.connectSSHAsync(serverId: serverId)
                await MainActor.run { updateTabSessionId(tabId, sessionId: sessionId) }
            } catch {
                await MainActor.run {
                    alertTitle = "连接失败"
                    alertMessage = "\(error.localizedDescription)"
                }
            }
        }
    }

    private func clearTemporaryDraft(tabId: String) {
        tabState.temporaryTabTokens.removeValue(forKey: tabId)
        tabState.temporaryPromotionFailures.removeValue(forKey: tabId)
        guard var draft = tabState.temporaryDrafts[tabId] else { return }
        draft.clearSecrets()
        tabState.temporaryDrafts[tabId] = draft
        tabState.temporaryDrafts.removeValue(forKey: tabId)
    }

    func openDialog(server: Server? = nil, defaults: ServerInput? = nil) {
        editingServer = server
        dialogDefaults = defaults
        dialogOpen = true
    }

    func closeDialog() {
        dialogOpen = false
        editingServer = nil
        dialogDefaults = nil
    }

    func openCgDialog(_ cg: CredentialGroup? = nil) {
        editingCg = cg
        cgDialogOpen = true
    }

    func closeCgDialog() {
        cgDialogOpen = false
        editingCg = nil
    }

    func handleChannelClosed(channelId: String) {
        guard let tabIdx = tabs.firstIndex(where: { tab in
            if let tree = tab.paneTree {
                return tree.contains(channelId)
            }
            return tab.sessionId == channelId
        }) else { return }

        let tab = tabs[tabIdx]

        // Clean up handlers and disconnect the dead channel
        bridge.removeSSHHandlers(sessionId: channelId)
        bridge.removeTerminalView(sessionId: channelId)
        Task { try? await bridge.disconnectSSHAsync(sessionId: channelId) }

        if let tree = tab.paneTree {
            // Split pane: remove this leaf from the tree
            if let newTree = tree.removing(channelId: channelId) {
                if case .leaf(let remaining) = newTree {
                    tabs[tabIdx].paneTree = nil
                    if tab.id == activeTabId, tabs[tabIdx].focusedChannelId != nil {
                        closeSessionScopedTools()
                    }
                    tabs[tabIdx].focusedChannelId = nil
                    if tabs[tabIdx].sessionId == channelId {
                        tabs[tabIdx].sessionId = remaining
                    }
                } else {
                    tabs[tabIdx].paneTree = newTree
                    let nextFocusedChannelId = tab.focusedChannelId == channelId
                        ? newTree.channelIds.first
                        : tab.focusedChannelId
                    if tab.id == activeTabId, tabs[tabIdx].focusedChannelId != nextFocusedChannelId {
                        closeSessionScopedTools()
                    }
                    tabs[tabIdx].focusedChannelId = nextFocusedChannelId
                    if tabs[tabIdx].sessionId == channelId {
                        tabs[tabIdx].sessionId = newTree.channelIds.first
                    }
                }
            } else {
                // All panes closed
                removeTab(tab.id)
            }
        } else {
            // Single pane: close the whole tab
            removeTab(tab.id)
        }
    }

    func openSpotlight() {
        spotlightQuery = ""
        spotlightOpen = true
    }

    func closeSpotlight() {
        spotlightOpen = false
        spotlightQuery = ""
    }

    func toggleSftpDrawer(for tabId: String) {
        if requestActivateTab(tabId) {
            openTool(.sftp)
        }
    }

    func setTheme(_ newTheme: AppTheme) {
        theme = newTheme
        UserDefaults.standard.set(newTheme.rawValue, forKey: "theme")
    }

    func reconnectTab(_ tabId: String) {
        guard let tabIdx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[tabIdx]
        guard tab.type == .terminal else { return }

        // Clear old session state
        if let oldSid = tab.sessionId {
            bridge.removeSSHHandlers(sessionId: oldSid)
            bridge.removeTerminalView(sessionId: oldSid)
        }
        tabs[tabIdx].sessionId = nil
        if tabId == activeTabId, tabs[tabIdx].focusedChannelId != nil {
            closeSessionScopedTools()
        }
        tabs[tabIdx].focusedChannelId = nil
        tabs[tabIdx].paneTree = nil

        // Reconnect
        if case .saved(let serverId) = tab.connectionTarget {
            connectSSH(tabId: tabId, serverId: serverId)
        }
    }

    // MARK: - Command Snippets

    func loadSnippets() {
        guard let data = UserDefaults.standard.data(forKey: "commandSnippets") else { return }
        do {
            snippets = try Self.decoder.decode([CommandSnippet].self, from: data)
        } catch {
            print("[Orbit] Failed to load snippets: \(error)")
        }
    }

    func saveSnippets() {
        do {
            let data = try Self.encoder.encode(snippets)
            UserDefaults.standard.set(data, forKey: "commandSnippets")
        } catch {
            print("[Orbit] Failed to save snippets: \(error)")
        }
    }

    func addSnippet(_ input: CommandSnippetInput) {
        let id = "snip-\(Int(Date().timeIntervalSince1970 * 1000))"
        let now = Date()
        let snippet = CommandSnippet(
            id: id, name: input.name, command: input.command,
            description: input.description, tags: input.tags,
            serverId: input.serverId, createdAt: now, updatedAt: now
        )
        snippets.append(snippet)
        saveSnippets()
    }

    func updateSnippet(id: String, input: CommandSnippetInput) {
        if let idx = snippets.firstIndex(where: { $0.id == id }) {
            let now = Date()
            let updated = CommandSnippet(
                id: id, name: input.name, command: input.command,
                description: input.description, tags: input.tags,
                serverId: input.serverId, createdAt: snippets[idx].createdAt, updatedAt: now
            )
            snippets[idx] = updated
            saveSnippets()
        }
    }

    func deleteSnippet(_ id: String) {
        snippets.removeAll { $0.id == id }
        saveSnippets()
    }

    func openSnippetEditor(snippet: CommandSnippet? = nil) {
        editingSnippet = snippet
        snippetEditorOpen = true
    }

    func closeSnippetEditor() {
        snippetEditorOpen = false
        editingSnippet = nil
    }

    func insertSnippetCommand(_ template: String, into terminalView: OrbitTerminalView?) {
        guard let tv = terminalView else { return }
        let resolved = resolveTemplate(template)
        tv.insertInputText(resolved)
    }

    func resolveTemplate(_ template: String) -> String {
        var result = template
        var server: Server?
        if let active = activeTabId, let tab = tabs.first(where: { $0.id == active }) {
            server = servers.first(where: { $0.id == tab.serverId })
        }
        let replacements: [(String, String)] = [
            ("{{host}}", server?.host ?? ""),
            ("{{user}}", server?.username ?? ""),
            ("{{port}}", server.map { String($0.port) } ?? ""),
            ("{{server_name}}", server?.name ?? ""),
            ("{{group}}", server?.group_name ?? ""),
        ]
        for (placeholder, value) in replacements {
            result = result.replacingOccurrences(of: placeholder, with: value)
        }
        return result
    }

    func sendTerminalInput(_ input: String, sessionId: String) throws {
        if let terminalView = bridge.terminalView(for: sessionId) as? OrbitTerminalView {
            terminalView.insertInputText(input)
            return
        }
        try bridge.writeSSH(sessionId: sessionId, data: Data(input.utf8))
    }

    // MARK: - Keyword Highlighting

    func loadKeywords() {
        guard let data = UserDefaults.standard.data(forKey: "keywordHighlights") else { return }
        do {
            keywordHighlights = try Self.decoder.decode([KeywordHighlight].self, from: data)
        } catch {
            print("[Orbit] Failed to load keywords: \(error)")
        }
    }

    func saveKeywords() {
        do {
            let data = try Self.encoder.encode(keywordHighlights)
            UserDefaults.standard.set(data, forKey: "keywordHighlights")
        } catch {
            print("[Orbit] Failed to save keywords: \(error)")
        }
    }

    func addKeyword(pattern: String, colorHex: String) {
        let id = "kw-\(Int(Date().timeIntervalSince1970 * 1000))"
        keywordHighlights.append(KeywordHighlight(id: id, pattern: pattern, colorHex: colorHex, enabled: true))
        saveKeywords()
    }

    func updateKeyword(id: String, pattern: String, colorHex: String, enabled: Bool) {
        if let idx = keywordHighlights.firstIndex(where: { $0.id == id }) {
            keywordHighlights[idx] = KeywordHighlight(id: id, pattern: pattern, colorHex: colorHex, enabled: enabled)
            saveKeywords()
        }
    }

    func deleteKeyword(_ id: String) {
        keywordHighlights.removeAll { $0.id == id }
        saveKeywords()
    }

    // MARK: - AI Configuration

    func loadAIConfig() {
        guard let data = UserDefaults.standard.data(forKey: "aiConfig") else { return }
        do {
            aiConfig = try Self.decoder.decode(AIConfig.self, from: data)
        } catch {
            print("[Orbit] Failed to load AI config: \(error)")
        }
    }

    func saveAIConfig() {
        do {
            let data = try Self.encoder.encode(aiConfig)
            UserDefaults.standard.set(data, forKey: "aiConfig")
        } catch {
            print("[Orbit] Failed to save AI config: \(error)")
        }
    }

    func addMessageToCurrentSession(_ message: AIChatMessage, shouldSave: Bool = true) {
        let serverId = currentServerId
        let tabId = currentActiveTabId

        var session = ensureSession(tabId: tabId, serverId: serverId)

        if session.title.isEmpty && message.role == "user" {
            let t = message.content.trimmingCharacters(in: .whitespaces)
            session.title = String(t.prefix(30))
        }

        session.messages.append(message)
        session.updatedAt = Date()

        if let idx = aiSessions[serverId]?.firstIndex(where: { $0.id == session.id }) {
            aiSessions[serverId]?[idx] = session
        }
        if shouldSave {
            saveAISessions(serverId: serverId)
        }
    }

    func clearCurrentSessionMessages() {
        let serverId = currentServerId
        let tabId = currentActiveTabId
        guard let sessionId = activeAISessionId[tabId],
              var sessions = aiSessions[serverId],
              let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].messages.removeAll()
        sessions[idx].updatedAt = Date()
        aiSessions[serverId] = sessions
        saveAISessions(serverId: serverId)
    }

    func toggleAIPanel() {
        toggleAIDrawerForCurrentContext()
    }

    func submitAIQuestion(_ question: String) {
        let serverId = currentServerId
        let tabId = currentActiveTabId

        let userMsg = AIChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: question,
            timestamp: Date()
        )
        let _ = ensureSession(tabId: tabId, serverId: serverId)
        addMessageToCurrentSession(userMsg)

        if !aiPanelOpen {
            aiPanelOpen = true
        }
    }

    // MARK: - Batch Execution

    func sendToMultipleServers(command: String, serverIds: [String]) {
        for serverId in serverIds {
            Task {
                do {
                    let sessionId = try await bridge.connectSSHAsync(serverId: serverId)
                    try bridge.writeSSH(sessionId: sessionId, data: Data((command + "\r").utf8))
                } catch {
                    print("[Orbit] Batch exec to \(serverId) failed: \(error)")
                }
            }
        }
    }

    // MARK: - AI Session Helpers

    private static let standaloneServerId = "_standalone_"
    private static let standaloneTabId = "_standalone_tab_"

    var currentServerId: String {
        if let activeId = activeTabId,
           let tab = tabs.first(where: { $0.id == activeId }) {
            switch tab.connectionTarget {
            case .saved(let serverId):
                return serverId
            case .temporary(let tabId):
                return "temporary:\(tabId)"
            case .local:
                return "local"
            }
        }
        return Self.standaloneServerId
    }

    private var currentActiveTabId: String {
        activeTabId ?? Self.standaloneTabId
    }

    var currentSession: AISession? {
        let sid = currentServerId
        let tid = currentActiveTabId
        guard let sessionId = activeAISessionId[tid],
              let sessions = aiSessions[sid],
              let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return nil }
        return aiSessions[sid]?[idx]
    }

    var currentMessages: [AIChatMessage] {
        currentSession?.messages ?? []
    }

    func ensureSession(tabId: String, serverId: String) -> AISession {
        if let sessionId = activeAISessionId[tabId],
           let sessions = aiSessions[serverId],
           let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            return sessions[idx]
        }
        let session = AISession.create(serverId: serverId)
        if aiSessions[serverId] == nil {
            aiSessions[serverId] = []
        }
        aiSessions[serverId]?.insert(session, at: 0)
        activeAISessionId[tabId] = session.id
        saveAISessions(serverId: serverId)
        return session
    }

    func currentSessionTitle() -> String {
        currentSession?.title ?? ""
    }

    func loadAISessions(serverId: String) {
        guard let data = UserDefaults.standard.data(forKey: "aiSessions_\(serverId)") else { return }
        do {
            aiSessions[serverId] = try Self.decoder.decode([AISession].self, from: data)
        } catch {
            print("[Orbit] Failed to load AI sessions for \(serverId): \(error)")
        }
    }

    func saveAISessions(serverId: String) {
        guard let sessions = aiSessions[serverId] else { return }
        do {
            let data = try Self.encoder.encode(sessions)
            UserDefaults.standard.set(data, forKey: "aiSessions_\(serverId)")
        } catch {
            print("[Orbit] Failed to save AI sessions for \(serverId): \(error)")
        }
    }

    func loadAIPanelWidth() {
        let w = UserDefaults.standard.double(forKey: "aiPanelWidth")
        if w >= 160 && w <= 600 { aiPanelWidth = w }
    }

    func saveAIPanelWidth(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: "aiPanelWidth")
    }

    // MARK: - Slash Commands

    enum SlashCommandResult {
        case handled(String)
        case switchSession(String)
        case ignore
    }

    func handleSlashCommand(_ input: String) -> SlashCommandResult {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        if trimmed == "/new" { return createNewSession() }
        if trimmed == "/sessions" { return listSessions() }
        if trimmed == "/compact" { return compactCurrentSession() }

        if trimmed.hasPrefix("/load ") {
            let sessionId = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return loadSession(sessionId: sessionId)
        }

        return .ignore
    }

    private func createNewSession() -> SlashCommandResult {
        let serverId = currentServerId
        let tabId = currentActiveTabId
        saveAISessions(serverId: serverId)

        let session = AISession.create(serverId: serverId)
        if aiSessions[serverId] == nil { aiSessions[serverId] = [] }
        aiSessions[serverId]?.insert(session, at: 0)
        activeAISessionId[tabId] = session.id
        saveAISessions(serverId: serverId)
        return .handled("已创建新会话")
    }

    private func listSessions() -> SlashCommandResult {
        let serverId = currentServerId
        loadAISessions(serverId: serverId)
        let sessions = aiSessions[serverId] ?? []
        if sessions.isEmpty { return .handled("当前没有历史会话") }
        let df = aiDateFormatter
        var lines = ["📋 **历史会话** (点击加载, 或用 `/load <id>`):"]
        for s in sessions {
            let dateStr = df.string(from: s.updatedAt)
            let title = s.title.isEmpty ? "（空会话）" : s.title
            let marker = activeAISessionId[currentActiveTabId] == s.id ? " ●" : ""
            lines.append("- `\(s.id.prefix(8))` \(title) (\(s.messages.count) 条消息, \(dateStr))\(marker)")
        }
        return .handled(lines.joined(separator: "\n"))
    }

    private func loadSession(sessionId: String) -> SlashCommandResult {
        let serverId = currentServerId
        let tabId = currentActiveTabId
        guard let sessions = aiSessions[serverId] else {
            return .handled("无法加载 session")
        }
        let match = sessions.first(where: { $0.id.hasPrefix(sessionId) })
        guard let session = match else {
            return .handled("未找到 session: \(sessionId)")
        }
        activeAISessionId[tabId] = session.id
        return .switchSession(session.id)
    }

    private func compactCurrentSession() -> SlashCommandResult {
        let serverId = currentServerId
        let tabId = currentActiveTabId
        guard let sessionId = activeAISessionId[tabId],
              var sessions = aiSessions[serverId],
              let idx = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return .handled("无法压缩：无活跃会话")
        }
        let msgs = sessions[idx].messages
        guard msgs.count >= 4 else {
            return .handled("消息太少，无需压缩")
        }

        let splitIdx = max(1, Int(Double(msgs.count) * 0.7))
        let toCompress = Array(msgs[0..<splitIdx])
        let toKeep = Array(msgs[splitIdx...])

        let summaryContent = "[上下文摘要] 前 \(toCompress.count) 条消息已压缩。"
        let summaryMsg = AIChatMessage(
            id: UUID().uuidString, role: "system",
            content: summaryContent, timestamp: Date())

        sessions[idx].messages = [summaryMsg] + toKeep
        sessions[idx].updatedAt = Date()
        aiSessions[serverId] = sessions
        saveAISessions(serverId: serverId)

        return .handled("已压缩上下文：将前 \(toCompress.count) 条消息替换为摘要，保留 \(toKeep.count) 条")
    }

    private var aiDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    // MARK: - Command Safety Whitelist

    struct CommandSafety {
        static let safePrefixes: [String] = [
            "ls ", "cat ", "head ", "tail ", "less ", "file ", "stat ", "du ",
            "grep ", "awk ", "sed -n", "wc ", "sort ", "uniq ", "cut ", "tr ",
            "ps ", "top -bn", "htop -n", "free ", "df ", "uptime", "uname", "hostname", "whoami", "id ",
            "ping -c", "curl -I", "wget --spider", "ss -tlnp", "ss -tuln",
            "netstat ", "ip addr show", "ip a ", "nslookup ", "dig ",
            "systemctl status", "journalctl ", "service ", "pgrep ", "pidof ",
            "lsof -p", "dmesg", "last ", "lastlog",
            "echo ", "printf ", "pwd", "env ", "printenv", "which ", "whereis", "type ",
            "find ", "locate ", "dpkg -l", "rpm -q", "pip list",
            "docker ps", "docker images", "docker inspect", "docker logs",
        ]

        static let dangerousPatterns: [String] = [
            "rm ", "mv ", "cp ", "chmod ", "chown ",
            "kill ", "pkill", "killall",
            "systemctl start", "systemctl stop", "systemctl restart",
            "systemctl enable", "systemctl disable", "systemctl mask",
            "apt install", "apt remove", "apt purge", "apt-get",
            "yum install", "yum remove", "dnf install", "dnf remove",
            "brew install", "brew uninstall", "pip install", "pip uninstall",
            "npm install -g", "npm uninstall -g",
            "dd ", "mkfs", "fdisk", "parted",
            "shutdown", "reboot", "halt", "poweroff",
            "> ", ">>",
        ]

        static func riskReason(command: String) -> String? {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return "空命令" }
            if trimmed.contains("sudo") { return "包含 sudo 权限提升" }
            for pattern in dangerousPatterns {
                if trimmed.contains(pattern.lowercased()) {
                    return "包含高风险片段: \(pattern.trimmingCharacters(in: .whitespaces))"
                }
            }
            return nil
        }

        static func isSafe(command: String) -> Bool {
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }

            if riskReason(command: command) != nil { return false }

            for prefix in safePrefixes {
                if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                    return true
                }
            }

            return false
        }
    }

    // MARK: - Asset Tree & Recent Servers

    func loadAssetTreeWidth() {
        let w = UserDefaults.standard.double(forKey: "assetTreeWidth")
        if w >= 160 && w <= 350 { assetTreeWidth = w }
    }

    func saveAssetTreeWidth(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: "assetTreeWidth")
    }

    func loadRecentServers() {
        guard let data = UserDefaults.standard.data(forKey: "recentServers") else { return }
        do {
            recentServers = try Self.decoder.decode([String].self, from: data)
        } catch {
            print("[Orbit] Failed to load recent servers: \(error)")
        }
    }

    func loadPortForwardRules() {
        guard let data = UserDefaults.standard.data(forKey: "portForwardRules") else { return }
        do {
            portForwardRules = try Self.decoder.decode([PortForwardRule].self, from: data)
        } catch {
            print("[Orbit] Failed to load port forward rules: \(error)")
        }
    }

    func savePortForwardRules() {
        do {
            let data = try Self.encoder.encode(portForwardRules)
            UserDefaults.standard.set(data, forKey: "portForwardRules")
        } catch {
            print("[Orbit] Failed to save port forward rules: \(error)")
        }
    }

    func addPortForwardRule(serverId: String, localPort: UInt16, remoteHost: String, remotePort: UInt16) {
        let id = "pf-\(Int(Date().timeIntervalSince1970 * 1000))"
        let rule = PortForwardRule(id: id, serverId: serverId, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort, enabled: false)
        portForwardRules.append(rule)
        savePortForwardRules()
    }

    func startPortForward(_ rule: PortForwardRule) {
        Task {
            do {
                let actualPort = try await bridge.startPortForwardAsync(forwardingId: rule.id, serverId: rule.serverId, localPort: rule.localPort, remoteHost: rule.remoteHost, remotePort: rule.remotePort)
                await MainActor.run {
                    if let idx = portForwardRules.firstIndex(where: { $0.id == rule.id }) {
                        portForwardRules[idx].enabled = true
                        if actualPort != rule.localPort, actualPort != 0 {
                            portForwardRules[idx] = PortForwardRule(id: rule.id, serverId: rule.serverId, localPort: actualPort, remoteHost: rule.remoteHost, remotePort: rule.remotePort, enabled: true)
                        }
                        savePortForwardRules()
                    }
                }
            } catch {
                await MainActor.run {
                    alertTitle = "端口转发失败"
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    func stopPortForward(_ rule: PortForwardRule) {
        Task {
            do {
                try await bridge.stopPortForwardAsync(forwardingId: rule.id)
            } catch { }
            await MainActor.run {
                if let idx = portForwardRules.firstIndex(where: { $0.id == rule.id }) {
                    portForwardRules[idx].enabled = false
                    savePortForwardRules()
                }
            }
        }
    }

    func removePortForwardRule(_ rule: PortForwardRule) {
        if rule.enabled {
            Task { try? await bridge.stopPortForwardAsync(forwardingId: rule.id) }
        }
        portForwardRules.removeAll { $0.id == rule.id }
        savePortForwardRules()
    }

    func saveRecentServers() {
        do {
            let data = try Self.encoder.encode(recentServers)
            UserDefaults.standard.set(data, forKey: "recentServers")
        } catch {
            print("[Orbit] Failed to save recent servers: \(error)")
        }
    }

    func trackRecentServer(_ serverId: String) {
        recentServers.removeAll { $0 == serverId }
        recentServers.insert(serverId, at: 0)
        if recentServers.count > 6 { recentServers = Array(recentServers.prefix(6)) }
        saveRecentServers()
    }

    func updateServerGroupName(oldName: String, newName: String) {
        let targets = servers.filter { ($0.group_name.isEmpty ? "默认" : $0.group_name) == oldName }
        for server in targets {
            let input = ServerInput(
                name: server.name,
                host: server.host,
                port: server.port,
                group_name: newName,
                auth_type: server.auth_type,
                username: server.username,
                password: server.password,
                private_key: server.private_key,
                key_source: server.key_source,
                key_file_path: server.key_file_path,
                key_passphrase: server.key_passphrase,
                credential_group_id: server.credential_group_id,
                jump_server_id: server.jump_server_id
            )
            updateServer(id: server.id, input: input)
        }
    }
}

enum WorkspaceError: LocalizedError, Equatable {
    case missingTemporaryDraft
    case localConnectionHandledSeparately
    case promotionInProgress
    case staleTemporarySession

    var errorDescription: String? {
        switch self {
        case .missingTemporaryDraft:
            return "临时连接草稿不存在"
        case .localConnectionHandledSeparately:
            return "本地终端由本地 Shell 建立连接"
        case .promotionInProgress:
            return "该临时连接正在保存"
        case .staleTemporarySession:
            return "临时连接会话已变更"
        }
    }
}

enum TemporaryPromotionOutcome: Equatable {
    case promoted(serverId: String)
    case persistedAfterTabClosed(serverId: String)
    case persistedWithoutRebinding(serverId: String)
}

extension TemporaryConnectionDraft {
    var connectionInput: TemporaryConnectionInput {
        let credentialId = credentialGroupId?.nonempty
        let usesCredentialGroup = credentialId != nil
        let usesPassword = !usesCredentialGroup && authType == "password"
        let usesKey = !usesCredentialGroup && authType == "key"

        return TemporaryConnectionInput(
            host: host,
            port: port,
            username: username,
            auth_type: authType,
            password: usesPassword ? password.nonempty : nil,
            private_key: usesKey && keySource == "content" ? privateKey.nonempty : nil,
            key_source: usesKey ? keySource.nonempty : nil,
            key_file_path: usesKey && keySource == "file" ? keyFilePath.nonempty : nil,
            key_passphrase: usesKey ? keyPassphrase.nonempty : nil,
            credential_group_id: credentialId,
            jump_server_id: jumpServerId?.nonempty
        )
    }

    var promotionInput: PromoteTemporaryServerInput {
        PromoteTemporaryServerInput(
            connection: connectionInput,
            name: displayName.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? host,
            folder_id: folderId?.nonempty,
            tag_ids: tagIds
        )
    }
}

private extension String {
    var nonempty: String? {
        isEmpty ? nil : self
    }
}
