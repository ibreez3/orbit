import SwiftUI

struct DatabaseView: View {
    let tab: TabItem
    let appState: AppState
    @State private var browsing = false
    @State private var browseResult: DatabaseQueryResult?
    @State private var databaseName = ""
    @State private var schema: DatabaseSchema?
    @State private var queryResult: DatabaseQueryResult?
    @State private var errorMessage: String?
    @State private var isLoadingSchema = false
    @State private var isExecuting = false
    @State private var schemaRequestRevision = 0
    @State private var queryRequestRevision = 0
    @State private var selectedTable: String? = nil
    @State private var sqlText: String = ""
    @State private var tableSearchQuery: String = ""
    @State private var showRestoreSheet = false
    @State private var showImportMapping = false
    @State private var isBackupRunning = false
    @State private var backupStatusMessage: String?
    @State private var backupStatusIsError = false
    @AppStorage("dbDefaultLimit") private var dbDefaultLimit: Double = 200
    @AppStorage("dbQueryTimeout") private var dbQueryTimeout: Double = 30
    @AppStorage("dbReadOnlyMode") private var dbReadOnlyMode: Bool = false
    @AppStorage("dbAutoLimit") private var dbAutoLimit: Bool = true

    private var connection: DatabaseConnection? {
        appState.databaseConnections.first { $0.id == tab.serverId }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let connection, connection.engine == "mysql" {
                DatabaseCatalogPicker(appState: appState, connection: connection, selection: Binding(get: { databaseName }, set: switchDatabase))
                    .disabled(isExecuting || isLoadingSchema || isBackupRunning)
                    .padding(8)
                Divider()
            }
            HSplitView {
                tableListPanel
                editorAndResultsPanel
            }
        }
        .onAppear {
            restoreSnapshot()
            applyDatabaseSettings()
            publishAIContext()
            Task { await loadSchema() }
        }
        .onChange(of: appState.databasePanelInvalidationToken(for: tab.id)) { _ in
            clearLoadedState()
            publishAIContext()
            Task { await loadSchema() }
        }
        .onChange(of: selectedTable) { _ in
            saveSnapshot()
            publishAIContext()
        }
        .onChange(of: sqlText) { _ in
            saveSnapshot()
            publishAIContext()
        }
        .onChange(of: dbDefaultLimit) { _ in applyDatabaseSettings() }
        .onChange(of: dbAutoLimit) { _ in applyDatabaseSettings() }
        .sheet(isPresented: $showRestoreSheet) {
            DatabaseBackupSheet(appState: appState, initialTargetConnectionId: connection?.id, initialDatabaseName: databaseName)
                .environmentObject(appState.inventoryState)
        }
        .sheet(isPresented: $showImportMapping) {
            DatabaseImportMappingView(appState: appState, initialTargetConnectionId: connection?.id, initialDatabaseName: databaseName)
                .environmentObject(appState.inventoryState)
        }
    }

    private var tableListPanel: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索表…", text: $tableSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }

                HStack(spacing: 6) {
                    connectionBadge
                    Spacer()
                    Button(action: { Task { await backupCurrentDatabase() } }) {
                        operationIcon("archivebox")
                    }
                    .buttonStyle(.plain)
                    .disabled(isBackupRunning || connection == nil)
                    .help("一键备份")

                    Button(action: { showRestoreSheet = true }) {
                        operationIcon("arrow.counterclockwise.icloud")
                    }
                    .buttonStyle(.plain)
                    .disabled(connection == nil)
                    .help("恢复备份")

                    Button(action: { showImportMapping = true }) {
                        operationIcon("arrow.triangle.branch")
                    }
                    .buttonStyle(.plain)
                    .help("SQLite 导入 MySQL")

                    Button(action: { Task { await loadSchema() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingSchema || connection == nil)
                    .help("刷新 Schema")
                }
            }
            .padding(8)
            .background(.ultraThinMaterial)

            Divider()

            if isLoadingSchema {
                ProgressView("加载 Schema…")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if connection == nil {
                emptyPanel("数据库连接不存在")
            } else if filteredTables.isEmpty {
                emptyPanel(schema == nil ? "尚未加载 Schema" : "没有匹配的表")
            } else {
                List {
                    ForEach(filteredTables) { table in
                        Button {
                            selectTable(table.name)
                        } label: {
                            TableSchemaRow(table: table)
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.plain)
                            .listRowBackground(selectedTable == table.name ? Color.accentColor.opacity(0.12) : Color.clear)
                            .contextMenu {
                                Button("查看前 200 行") {
                                    selectTable(table.name)
                                }
                                Button("复制表名") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(table.name, forType: .string)
                                }
                            }
                        if selectedTable == table.name {
                            ForEach(table.columns) { column in
                                HStack(spacing: 6) {
                                    Image(systemName: column.primary_key ? "key.fill" : "number")
                                        .font(.system(size: 9))
                                        .foregroundStyle(column.primary_key ? Color.yellow : Color.gray)
                                        .frame(width: 12)
                                    Text(column.name)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(column.db_type)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 18)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .disabled(isExecuting)
            }
        }
        .frame(minWidth: 210, idealWidth: 250, maxWidth: 340)
    }

    private var editorAndResultsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("视图", selection: $browsing) {
                    Text("表数据").tag(true)
                    Text("SQL 查询").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .disabled(isExecuting)
                if browsing, let selectedTable {
                    Text("\(selectedTable) · 前 200 行").font(.caption)
                    Button("刷新数据") { selectTable(selectedTable) }
                        .disabled(isExecuting)
                }
                Spacer()
            }.padding(8)
            if !browsing { sqlEditor }
            if browsing, let errorMessage { Text(errorMessage).foregroundStyle(.red).padding(8) }
            Divider()
            resultsPanel
        }
    }

    private var sqlEditor: some View {
        VStack(spacing: 0) {
            if let backupStatusMessage {
                HStack(spacing: 8) {
                    Image(systemName: backupStatusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(backupStatusMessage)
                        .font(.system(size: 11))
                        .lineLimit(2)
                    Spacer()
                    Button(action: { self.backupStatusMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                }
                .foregroundStyle(backupStatusIsError ? Color.red : Color.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background((backupStatusIsError ? Color.red : Color.green).opacity(0.08))
            }

            TextEditor(text: $sqlText)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .scrollContentBackground(.hidden)

            HStack(spacing: 10) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("只读", isOn: $dbReadOnlyMode)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                Button(action: formatQuery) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("格式化")

                Button(action: { Task { await executeSQL() } }) {
                    HStack(spacing: 5) {
                        if isExecuting {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                        }
                        Text("执行")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(canExecuteQuery ? Color.accentColor : Color.gray.opacity(0.3))
                    .foregroundStyle(canExecuteQuery ? .white : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canExecuteQuery || isExecuting || connection == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .frame(minHeight: 130)
    }

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            if isExecuting {
                ProgressView("执行 SQL…")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = browsing ? browseResult : queryResult {
                queryResultView(result)
            } else {
                emptyPanel("执行 SQL 查看结果")
            }

            HStack(spacing: 10) {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if dbReadOnlyMode {
                    Text("只读")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Text("\(Int(dbQueryTimeout))s 超时")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("⌘Enter 执行")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "cylinder")
                .font(.system(size: 10))
                .foregroundStyle(.purple)
            Text(connection?.name ?? tab.serverName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
    }

    private func operationIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 20, height: 20)
    }

    private func queryResultView(_ result: DatabaseQueryResult) -> some View {
        VStack(spacing: 0) {
            if !result.columns.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ResultRow(cells: result.columns.map { $0 }, isHeader: true)
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in
                            ResultRow(cells: row.map { $0 ?? "NULL" }, isHeader: false)
                        }
                    }
                    .padding(8)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                    Text(result.message.isEmpty ? "语句执行完成" : result.message)
                        .font(.system(size: 13))
                    Text("影响行数 \(result.affected_rows)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var filteredTables: [DatabaseTableSchema] {
        let all = schema?.tables ?? []
        let q = tableSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q)
                || $0.columns.contains { $0.name.lowercased().contains(q) }
        }
    }

    private var canExecuteQuery: Bool {
        let trimmed = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, connection?.engine != "mysql" || !(connection?.database_name ?? "").isEmpty || !databaseName.isEmpty else { return false }
        return !dbReadOnlyMode || !isWriteStatement(trimmed)
    }

    private var statusText: String {
        if let queryResult = browsing ? browseResult : queryResult {
            if !queryResult.columns.isEmpty {
                return "\(queryResult.rows.count) 行，\(queryResult.columns.count) 列，\(queryResult.elapsed_ms) ms"
            }
            return "影响 \(queryResult.affected_rows) 行，\(queryResult.elapsed_ms) ms"
        }
        return schema.map { "\($0.tables.count) 张表" } ?? "Database"
    }

    @MainActor
    private func loadSchema() async {
        schemaRequestRevision += 1
        let schemaRevision = schemaRequestRevision
        let schemaInvalidationToken = appState.databasePanelInvalidationToken(for: tab.id)

        guard let connection else {
            guard isCurrentSchemaRequest(schemaRevision, invalidationToken: schemaInvalidationToken) else { return }
            isLoadingSchema = false
            errorMessage = "数据库连接不存在"
            publishAIContext()
            return
        }
        guard connection.engine != "mysql" || !connection.database_name.isEmpty || !databaseName.isEmpty else { return }
        isLoadingSchema = true
        errorMessage = nil
        do {
            let loaded = try await appState.bridge.listDatabaseSchemaAsync(connectionId: connection.id, databaseName: databaseName)
            guard isCurrentSchemaRequest(schemaRevision, invalidationToken: schemaInvalidationToken) else { return }
            schema = loaded
            if !loaded.tables.contains(where: { $0.name == selectedTable }) {
                selectedTable = loaded.tables.first?.name
            }
            saveSnapshot()
        } catch {
            guard isCurrentSchemaRequest(schemaRevision, invalidationToken: schemaInvalidationToken) else { return }
            errorMessage = error.localizedDescription
            saveSnapshot()
        }
        isLoadingSchema = false
        publishAIContext()
    }

    @MainActor
    private func executeSQL() async {
        queryRequestRevision += 1
        let queryRevision = queryRequestRevision
        let queryInvalidationToken = appState.databasePanelInvalidationToken(for: tab.id)

        guard let connection, canExecuteQuery else { return }
        isExecuting = true
        errorMessage = nil
        queryResult = nil
        do {
            let request = DatabaseQueryRequest(
                sql: DatabaseQueryPolicy.applyingAutoLimit(
                    to: sqlText,
                    limit: Int(dbDefaultLimit),
                    enabled: dbAutoLimit
                ),
                read_only: dbReadOnlyMode,
                timeout_ms: UInt32(dbQueryTimeout * 1000)
            )
            let result = try await appState.bridge.executeDatabaseQueryAsync(connectionId: connection.id, request: request, databaseName: databaseName)
            guard isCurrentQueryRequest(queryRevision, invalidationToken: queryInvalidationToken) else { return }
            queryResult = result
            saveSnapshot()
        } catch {
            guard isCurrentQueryRequest(queryRevision, invalidationToken: queryInvalidationToken) else { return }
            errorMessage = error.localizedDescription
            queryResult = nil
            saveSnapshot()
        }
        isExecuting = false
        publishAIContext()
    }

    private func selectTable(_ tableName: String) {
        guard !isExecuting, let connection, schema?.tables.contains(where: { $0.name == tableName }) == true else { return }
        selectedTable = tableName
        browsing = true
        browseResult = nil
        errorMessage = nil
        isExecuting = true
        queryRequestRevision += 1
        let revision = queryRequestRevision
        let token = appState.databasePanelInvalidationToken(for: tab.id)
        let database = databaseName
        Task { @MainActor in
            defer { if isCurrentQueryRequest(revision, invalidationToken: token) { isExecuting = false } }
            do {
                let request = DatabaseQueryRequest(sql: "SELECT * FROM \(quoteIdentifier(tableName)) LIMIT 200;", read_only: true, timeout_ms: UInt32(dbQueryTimeout * 1000))
                let result = try await appState.bridge.executeDatabaseQueryAsync(connectionId: connection.id, request: request, databaseName: database)
                guard isCurrentQueryRequest(revision, invalidationToken: token) else { return }
                browseResult = result
            } catch {
                guard isCurrentQueryRequest(revision, invalidationToken: token) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyDatabaseSettings() {
        guard dbAutoLimit else { return }
        let trimmed = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let table = selectedTable ?? schema?.tables.first?.name {
            sqlText = "SELECT * FROM \(quoteIdentifier(table)) LIMIT \(Int(dbDefaultLimit));"
        }
    }

    private func formatQuery() {
        sqlText = sqlText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func isWriteStatement(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["insert", "update", "delete", "drop", "alter", "create", "replace", "truncate", "vacuum", "attach", "detach", "pragma"]
            .contains { trimmed.hasPrefix($0) }
    }

    private func quoteIdentifier(_ value: String) -> String {
        DatabaseQueryPolicy.quoteIdentifier(value, engine: connection?.engine ?? "remote_sqlite")
    }

    @MainActor
    private func backupCurrentDatabase() async {
        guard let connection else { return }
        isBackupRunning = true
        backupStatusMessage = nil
        backupStatusIsError = false
        do {
            let result = try await appState.backupDatabaseConnectionResult(connection, databaseName: databaseName)
            backupStatusIsError = !result.ok
            backupStatusMessage = appState.databaseOperationMessage(result)
        } catch {
            backupStatusIsError = true
            backupStatusMessage = error.localizedDescription
        }
        isBackupRunning = false
    }

    private func switchDatabase(_ name: String) {
        guard name != databaseName else { return }
        databaseName = name
        clearLoadedState()
        sqlText = ""
        saveSnapshot()
        Task { await loadSchema() }
    }

    private func restoreSnapshot() {
        guard let snapshot = appState.databasePanelSnapshot(for: tab.id) else { return }
        databaseName = snapshot.databaseName
        schema = snapshot.schema
        selectedTable = snapshot.selectedTable
        if !snapshot.sqlText.isEmpty {
            sqlText = snapshot.sqlText
        }
        queryResult = snapshot.queryResult
        errorMessage = snapshot.error
    }

    private func clearLoadedState() {
        schemaRequestRevision += 1
        queryRequestRevision += 1
        isLoadingSchema = false
        isExecuting = false
        schema = nil
        browsing = false
        browseResult = nil
        selectedTable = nil
        queryResult = nil
        errorMessage = nil
    }

    @MainActor
    private func isCurrentSchemaRequest(_ revision: Int, invalidationToken: Int) -> Bool {
        revision == schemaRequestRevision
            && invalidationToken == appState.databasePanelInvalidationToken(for: tab.id)
    }

    @MainActor
    private func isCurrentQueryRequest(_ revision: Int, invalidationToken: Int) -> Bool {
        revision == queryRequestRevision
            && invalidationToken == appState.databasePanelInvalidationToken(for: tab.id)
    }

    private func saveSnapshot() {
        appState.saveDatabasePanelSnapshot(
            DatabasePanelSnapshot(
                databaseName: databaseName,
                schema: schema,
                selectedTable: selectedTable,
                sqlText: sqlText,
                queryResult: queryResult,
                error: errorMessage,
                lastUpdated: Date()
            ),
            for: tab.id
        )
    }

    private func publishAIContext() {
        let summary: String
        if let result = queryResult {
            if !result.columns.isEmpty {
                summary = "\(result.rows.count) rows, columns: \(result.columns.joined(separator: ", "))"
            } else {
                summary = result.message.isEmpty ? "Affected rows: \(result.affected_rows)" : result.message
            }
        } else if let errorMessage {
            summary = "错误: \(errorMessage)"
        } else {
            summary = "尚未执行查询"
        }
        appState.updateDatabaseAIContext(
            tabId: tab.id,
            selectedTable: selectedTable,
            sqlText: sqlText,
            resultSummary: summary
        )
    }

    private func emptyPanel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TableSchemaRow: View {
    let table: DatabaseTableSchema

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "tablecells")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(table.name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Text("\(table.columns.count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ResultRow: View {
    let cells: [String]
    let isHeader: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(.system(size: 11, weight: isHeader ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isHeader ? .primary : (cell == "NULL" ? .tertiary : .secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 150, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isHeader ? Color.primary.opacity(0.07) : Color.clear)
                    .border(Color.primary.opacity(0.08), width: 0.5)
            }
        }
    }
}

struct DatabaseCatalogPicker: View {
    let appState: AppState
    let connection: DatabaseConnection
    @Binding var selection: String
    @State private var databases: [String] = []
    @State private var error: String?

    var body: some View {
        HStack {
            if connection.database_name.isEmpty {
                Picker("数据库", selection: $selection) {
                    Text("选择数据库").tag("")
                    ForEach(databases, id: \.self) { Text($0).tag($0) }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } else {
                Text("数据库：\(connection.database_name)（固定）")
            }
            Spacer()
        }
        .task(id: connection.id + connection.database_name) {
            guard connection.database_name.isEmpty else { selection = connection.database_name; return }
            do {
                databases = try await appState.bridge.listDatabaseCatalogsAsync(connectionId: connection.id)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
