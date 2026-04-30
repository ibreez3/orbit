import SwiftUI

struct DatabaseView: View {
    let tab: TabItem
    @State private var selectedTable: String? = nil
    @State private var sqlText: String = "SELECT * FROM orders LIMIT 100;"
    @State private var tableSearchQuery: String = ""

    var body: some View {
        HSplitView {
            tableListPanel
            editorAndResultsPanel
        }
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
