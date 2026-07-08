import SwiftUI

struct DatabaseView: View {
    let tab: TabItem
    let appState: AppState
    @State private var schema: DatabaseSchema?
    @State private var queryResult: DatabaseQueryResult?
    @State private var errorMessage: String?
    @State private var isLoadingSchema = false
    @State private var isExecuting = false
    @State private var selectedTable: String? = nil
    @State private var sqlText: String = ""
    @State private var tableSearchQuery: String = ""
    @AppStorage("dbDefaultLimit") private var dbDefaultLimit: Double = 200
    @AppStorage("dbQueryTimeout") private var dbQueryTimeout: Double = 30
    @AppStorage("dbReadOnlyMode") private var dbReadOnlyMode: Bool = false
    @AppStorage("dbAutoLimit") private var dbAutoLimit: Bool = true

    private var connection: DatabaseConnection? {
        appState.databaseConnections.first { $0.id == tab.serverId }
    }

    var body: some View {
        HSplitView {
            tableListPanel
            editorAndResultsPanel
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
                List(selection: $selectedTable) {
                    ForEach(filteredTables) { table in
                        TableSchemaRow(table: table)
                            .tag(table.name)
                            .contextMenu {
                                Button("查询前 \(Int(dbDefaultLimit)) 行") {
                                    selectTable(table.name, replaceSQL: true)
                                }
                                Button("复制表名") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(table.name, forType: .string)
                                }
                            }
                            .onTapGesture {
                                selectTable(table.name, replaceSQL: false)
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
            }
        }
        .frame(minWidth: 210, idealWidth: 250, maxWidth: 340)
    }

    private var editorAndResultsPanel: some View {
        VStack(spacing: 0) {
            sqlEditor
            Divider()
            resultsPanel
        }
    }

    private var sqlEditor: some View {
        VStack(spacing: 0) {
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
            } else if let queryResult {
                queryResultView(queryResult)
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
        guard !trimmed.isEmpty else { return false }
        return !dbReadOnlyMode || !isWriteStatement(trimmed)
    }

    private var statusText: String {
        if let queryResult {
            if !queryResult.columns.isEmpty {
                return "\(queryResult.rows.count) 行，\(queryResult.columns.count) 列，\(queryResult.elapsed_ms) ms"
            }
            return "影响 \(queryResult.affected_rows) 行，\(queryResult.elapsed_ms) ms"
        }
        return schema.map { "\($0.tables.count) 张表" } ?? "Database"
    }

    @MainActor
    private func loadSchema() async {
        guard let connection else {
            errorMessage = "数据库连接不存在"
            return
        }
        isLoadingSchema = true
        errorMessage = nil
        do {
            let loaded = try await appState.bridge.listDatabaseSchemaAsync(connectionId: connection.id)
            schema = loaded
            if selectedTable == nil {
                selectedTable = loaded.tables.first?.name
            }
            saveSnapshot()
        } catch {
            errorMessage = error.localizedDescription
            saveSnapshot()
        }
        isLoadingSchema = false
        publishAIContext()
    }

    @MainActor
    private func executeSQL() async {
        guard let connection, canExecuteQuery else { return }
        isExecuting = true
        errorMessage = nil
        queryResult = nil
        do {
            let request = DatabaseQueryRequest(
                sql: sqlText,
                read_only: dbReadOnlyMode,
                timeout_ms: UInt32(dbQueryTimeout * 1000)
            )
            let result = try await appState.bridge.executeDatabaseQueryAsync(connectionId: connection.id, request: request)
            queryResult = result
            saveSnapshot()
        } catch {
            errorMessage = error.localizedDescription
            queryResult = nil
            saveSnapshot()
        }
        isExecuting = false
        publishAIContext()
    }

    private func selectTable(_ tableName: String, replaceSQL: Bool) {
        selectedTable = tableName
        let trimmed = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if replaceSQL || trimmed.isEmpty || trimmed.hasPrefix("SELECT * FROM") {
            sqlText = "SELECT * FROM \(quoteIdentifier(tableName)) LIMIT \(Int(dbDefaultLimit));"
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
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func restoreSnapshot() {
        guard let snapshot = appState.databasePanelSnapshot(for: tab.id) else { return }
        schema = snapshot.schema
        selectedTable = snapshot.selectedTable
        if !snapshot.sqlText.isEmpty {
            sqlText = snapshot.sqlText
        }
        queryResult = snapshot.queryResult
        errorMessage = snapshot.error
    }

    private func clearLoadedState() {
        schema = nil
        selectedTable = nil
        queryResult = nil
        errorMessage = nil
    }

    private func saveSnapshot() {
        appState.saveDatabasePanelSnapshot(
            DatabasePanelSnapshot(
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
