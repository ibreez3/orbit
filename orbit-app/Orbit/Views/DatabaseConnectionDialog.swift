import SwiftUI

struct DatabaseConnectionDialog: View {
    let appState: AppState
    @EnvironmentObject var inventoryState: InventoryState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var groupName: String = ""
    @State private var engine: DatabaseConnectionEngine = .remoteSQLite
    @State private var sshServerId: String = ""
    @State private var useSSHTunnel: Bool = false
    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var databaseName: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var sqlitePath: String = ""
    @State private var sslMode: String = ""

    private var editingConnection: DatabaseConnection? {
        appState.editingDatabaseConnection
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formContent
            Divider()
            footer
        }
        .frame(width: 520)
        .onAppear(perform: loadInitialValues)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 28, height: 28)
                .background(Color.purple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(editingConnection == nil ? "新建数据库连接" : "编辑数据库连接")
                    .font(.system(size: 15, weight: .semibold))
                Text(engine.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("基本信息") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    fieldRow("名称") {
                        TextField("Prod MySQL", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    fieldRow("分组") {
                        TextField("默认", text: $groupName)
                            .textFieldStyle(.roundedBorder)
                    }
                    fieldRow("类型") {
                        Picker("", selection: $engine) {
                            ForEach(DatabaseConnectionEngine.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: engine) { newValue in
                            applyDefaults(for: newValue)
                        }
                    }
                }
            }

            if engine == .remoteSQLite {
                section("远端 SQLite") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        serverPickerRow("SSH 服务器")
                        fieldRow("数据库路径") {
                            TextField("/var/lib/app/app.db", text: $sqlitePath)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            } else {
                section("连接参数") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        fieldRow("主机") {
                            TextField("127.0.0.1", text: $host)
                                .textFieldStyle(.roundedBorder)
                        }
                        fieldRow("端口") {
                            TextField(engine.defaultPort, text: $portText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                        }
                        fieldRow("数据库") {
                            TextField("app", text: $databaseName)
                                .textFieldStyle(.roundedBorder)
                        }
                        fieldRow("用户") {
                            TextField("user", text: $username)
                                .textFieldStyle(.roundedBorder)
                        }
                        fieldRow("密码") {
                            SecureField("密码", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }
                        fieldRow("SSL") {
                            TextField("prefer / require / disable", text: $sslMode)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                section("SSH 隧道") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("通过已配置 SSH 服务器连接", isOn: $useSSHTunnel)
                            .toggleStyle(.checkbox)
                            .onChange(of: useSSHTunnel) { enabled in
                                if enabled, sshServerId.isEmpty {
                                    sshServerId = inventoryState.servers.first?.id ?? ""
                                } else if !enabled {
                                    sshServerId = ""
                                }
                            }
                        if useSSHTunnel {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                serverPickerRow("跳板服务器")
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if inventoryState.databaseOperationLoading {
                ProgressView()
                    .scaleEffect(0.7)
            }
            Spacer()
            Button("取消") {
                appState.closeDatabaseConnectionDialog()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(editingConnection == nil ? "添加" : "保存") {
                appState.saveDatabaseConnectionFromDialog(input)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave || inventoryState.databaseOperationLoading)
        }
        .padding(16)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            content()
        }
    }

    private func serverPickerRow(_ title: String) -> some View {
        fieldRow(title) {
            Picker("", selection: $sshServerId) {
                Text("未选择").tag("")
                ForEach(inventoryState.servers) { server in
                    Text(server.name).tag(server.id)
                }
            }
            .labelsHidden()
        }
    }

    private var input: DatabaseConnectionInput {
        DatabaseConnectionInput(
            name: trimmed(name),
            group_name: trimmed(groupName).isEmpty ? nil : trimmed(groupName),
            engine: engine.rawValue,
            ssh_server_id: shouldPersistSSHServer ? (trimmed(sshServerId).isEmpty ? nil : trimmed(sshServerId)) : nil,
            use_ssh_tunnel: engine == .remoteSQLite ? false : useSSHTunnel,
            host: engine == .remoteSQLite ? nil : trimmed(host),
            port: engine == .remoteSQLite ? nil : UInt16(portText),
            database_name: engine == .remoteSQLite ? nil : trimmed(databaseName),
            username: engine == .remoteSQLite ? nil : trimmed(username),
            password: engine == .remoteSQLite ? nil : password,
            sqlite_path: engine == .remoteSQLite ? trimmed(sqlitePath) : nil,
            ssl_mode: engine == .remoteSQLite ? nil : trimmed(sslMode)
        )
    }

    private var shouldPersistSSHServer: Bool {
        engine == .remoteSQLite || useSSHTunnel
    }

    private var canSave: Bool {
        guard !trimmed(name).isEmpty else { return false }
        if engine == .remoteSQLite {
            return !trimmed(sshServerId).isEmpty && !trimmed(sqlitePath).isEmpty
        }
        guard UInt16(portText) != nil else { return false }
        if useSSHTunnel && trimmed(sshServerId).isEmpty { return false }
        return !trimmed(host).isEmpty && !trimmed(databaseName).isEmpty
    }

    private func loadInitialValues() {
        guard let connection = editingConnection else {
            if sshServerId.isEmpty {
                sshServerId = inventoryState.servers.first?.id ?? ""
            }
            applyDefaults(for: engine)
            return
        }

        name = connection.name
        groupName = connection.group_name
        engine = DatabaseConnectionEngine(rawValue: connection.engine) ?? .remoteSQLite
        sshServerId = connection.ssh_server_id
        useSSHTunnel = connection.use_ssh_tunnel
        host = connection.host
        portText = connection.port == 0 ? engine.defaultPort : "\(connection.port)"
        databaseName = connection.database_name
        username = connection.username
        password = connection.password
        sqlitePath = connection.sqlite_path
        sslMode = connection.ssl_mode
        if engine != .remoteSQLite && !useSSHTunnel {
            sshServerId = ""
        }
    }

    private func applyDefaults(for engine: DatabaseConnectionEngine) {
        if portText.isEmpty || ["3306", "5432"].contains(portText) {
            portText = engine.defaultPort
        }
        if engine == .remoteSQLite {
            useSSHTunnel = false
            if sshServerId.isEmpty {
                sshServerId = inventoryState.servers.first?.id ?? ""
            }
        } else if !useSSHTunnel {
            sshServerId = ""
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum DatabaseConnectionEngine: String, CaseIterable, Identifiable {
    case remoteSQLite = "remote_sqlite"
    case mysql
    case postgres

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remoteSQLite: return "Remote SQLite"
        case .mysql: return "MySQL"
        case .postgres: return "PostgreSQL"
        }
    }

    var defaultPort: String {
        switch self {
        case .remoteSQLite: return ""
        case .mysql: return "3306"
        case .postgres: return "5432"
        }
    }
}
