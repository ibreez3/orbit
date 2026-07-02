import SwiftUI

struct DatabaseView: View {
    let tab: TabItem
    let appState: AppState
    @State private var selectedTable: String? = nil
    @State private var sqlText: String = "SELECT * FROM orders LIMIT 100;"
    @State private var tableSearchQuery: String = ""
    @AppStorage("dbDefaultLimit") private var dbDefaultLimit: Double = 200
    @AppStorage("dbQueryTimeout") private var dbQueryTimeout: Double = 30
    @AppStorage("dbReadOnlyMode") private var dbReadOnlyMode: Bool = false
    @AppStorage("dbAutoLimit") private var dbAutoLimit: Bool = true

    var body: some View {
        HSplitView {
            tableListPanel
            editorAndResultsPanel
        }
        .onAppear {
            applyDatabaseSettings()
            publishAIContext()
        }
        .onChange(of: selectedTable) { _ in publishAIContext() }
        .onChange(of: sqlText) { _ in publishAIContext() }
        .onChange(of: dbDefaultLimit) { _ in applyDatabaseSettings() }
        .onChange(of: dbAutoLimit) { _ in applyDatabaseSettings() }
    }

    private var tableListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索表…", text: $tableSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(8)
            .background(.ultraThinMaterial)

            Divider()

            List(selection: $selectedTable) {
                ForEach(mockTables, id: \.self) { table in
                    HStack {
                        Image(systemName: "tablecells")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(table)
                            .font(.system(size: 12))
                    }
                    .tag(table)
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
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

            HStack {
                Spacer()
                Button("格式化") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(action: {}) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("执行")
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!canExecuteQuery)
                .opacity(canExecuteQuery ? 1 : 0.5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .frame(minHeight: 120)
    }

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            if selectedTable != nil {
                Table(mockResults) {
                    TableColumn("status") { row in Text(row.status) }
                    TableColumn("cnt") { row in Text("\(row.cnt)").frame(maxWidth: .infinity, alignment: .trailing) }
                }
                .tableStyle(.inset)
            } else {
                Text("执行 SQL 查看结果")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text("数据库面板（待接入后端）")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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

    private var mockTables: [String] {
        let all = ["orders", "users", "products", "payments", "sessions"]
        let q = tableSearchQuery.lowercased()
        if q.isEmpty { return all }
        return all.filter { $0.contains(q) }
    }

    private var canExecuteQuery: Bool {
        !dbReadOnlyMode || !isWriteStatement(sqlText)
    }

    private func applyDatabaseSettings() {
        guard dbAutoLimit else { return }
        let defaultSql = "SELECT * FROM orders LIMIT 100;"
        if sqlText == defaultSql || sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sqlText = "SELECT * FROM orders LIMIT \(Int(dbDefaultLimit));"
        }
    }

    private func isWriteStatement(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["insert", "update", "delete", "drop", "alter", "create", "replace", "truncate"]
            .contains { trimmed.hasPrefix($0) }
    }

    private func publishAIContext() {
        let summary: String
        if selectedTable != nil {
            summary = mockResults.map { "\($0.status): \($0.cnt)" }.joined(separator: ", ")
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
}

private struct MockResult: Identifiable {
    let id = UUID()
    let status: String
    let cnt: Int
}

private let mockResults = [
    MockResult(status: "PAID", cnt: 12042),
    MockResult(status: "PENDING", cnt: 642),
    MockResult(status: "FAILED", cnt: 39),
]
