import SwiftUI

struct DatabaseStructureView: View {
    let query: DatabaseTableQuery
    let readOnly: Bool
    @Binding var navigationLocked: Bool
    let execute: (String, Bool) async throws -> DatabaseQueryResult
    let export: (URL, Bool) async throws -> Void

    @State private var indexes: [DatabaseIndex] = []
    @State private var selected: String?
    @State private var loading = false
    @State private var adding = false
    @State private var deleting: DatabaseIndex?
    @State private var name = ""
    @State private var fields: [String] = []
    @State private var unique = false
    @State private var message = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(query.table.displayName, systemImage: "tablecells").fontWeight(.semibold)
                Spacer()
                Menu("导出 SQL") {
                    Button("仅表结构") { save(data: false) }
                    Button("表结构及全部数据") { save(data: true) }
                }.fixedSize()
            }.padding(8)
            Text("字段").font(.headline).padding(.horizontal, 8)
            Table(query.columns) {
                TableColumn("字段名") { Text($0.name) }
                TableColumn("类型") { Text($0.db_type) }
                TableColumn("允许 NULL") { Text($0.nullable ? "是" : "否") }
                TableColumn("默认值") { Text($0.default_value ?? "—") }
                TableColumn("属性") { col in Text([col.primary_key ? "主键" : nil, col.auto_generated == true ? "自动生成" : nil].compactMap { $0 }.joined(separator: " · ")) }
            }
            HStack {
                Text("索引").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                DatabaseToolButton(symbol: "plus", title: "新增索引") {
                    name = ""; fields = []; unique = false; adding = true
                }.disabled(readOnly)
                DatabaseToolButton(symbol: "minus", title: "删除所选索引") {
                    deleting = indexes.first { $0.id == selected }
                }.disabled(readOnly || indexes.first { $0.id == selected }?.protected != false)
                DatabaseToolButton(symbol: "arrow.clockwise", title: "刷新索引") { Task { await reload() } }
            }.disabled(loading).padding(8)
            Table(indexes, selection: $selected) {
                TableColumn("索引名") { index in
                    HStack { if index.protected { Image(systemName: "lock") }; Text(index.name) }
                }
                TableColumn("类型", value: \.kind).width(65)
                TableColumn("字段 / 定义") { Text($0.definition).help($0.definition).textSelection(.enabled) }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary).textSelection(.enabled).padding(8)
            }
        }
        .disabled(navigationLocked)
        .task { await reload() }
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 12) {
                Text("新增索引 · " + query.table.displayName).font(.headline)
                TextField("索引名", text: $name)
                Toggle("唯一索引", isOn: $unique)
                Text("索引字段（按添加顺序）").font(.caption)
                List {
                    ForEach(fields, id: \.self) { field in
                        HStack {
                            Text(field); Spacer()
                            DatabaseToolButton(symbol: "minus", title: "移除字段") { fields.removeAll { $0 == field } }
                        }
                    }
                }.frame(height: 110)
                Menu("添加字段") {
                    ForEach(query.columns.filter { !fields.contains($0.name) }) { col in Button(col.name) { fields.append(col.name) } }
                }
                HStack {
                    Spacer()
                    Button("取消") { adding = false }
                    Button("创建索引") {
                        guard let sql = query.createIndex(name, fields: fields, unique: unique) else { return }
                        adding = false
                        Task { await change(sql) }
                    }.disabled(readOnly || query.createIndex(name, fields: fields, unique: unique) == nil)
                }
            }.padding().frame(width: 400)
        }
        .alert("删除索引？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { index in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let sql = query.dropIndex(index) { Task { await change(sql) } }
            }
        } message: { index in Text(query.table.displayName + " · " + index.name) }
    }

    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            indexes = query.indexes(try await execute(query.indexListSQL, true))
            selected = nil
            failed = false
            message = indexes.isEmpty ? "没有独立索引" : ""
        } catch { indexes = []; selected = nil; failed = true; message = error.localizedDescription }
    }

    @MainActor private func change(_ sql: String) async {
        guard !readOnly, !navigationLocked else { return }
        navigationLocked = true
        defer { navigationLocked = false }
        do {
            _ = try await execute(sql, false)
            await reload()
        } catch { failed = true; message = error.localizedDescription }
    }

    @MainActor private func save(data: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = query.table.name.replacingOccurrences(of: "/", with: "_") + (data ? "-data.sql" : "-schema.sql")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        navigationLocked = true
        failed = false
        message = "正在导出 " + query.table.displayName + "…"
        Task {
            defer { navigationLocked = false }
            do {
                try await export(url, data)
                message = "已导出至 " + url.path
            } catch { failed = true; message = error.localizedDescription }
        }
    }
}
