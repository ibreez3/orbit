import SwiftUI

struct DatabaseToolButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}

struct DatabaseTableGrid: View {
    let query: DatabaseTableQuery
    let readOnly: Bool
    @Binding var navigationLocked: Bool
    let execute: (String, Bool) async throws -> DatabaseQueryResult

    private struct Cell: Hashable, Identifiable {
        let row: Int
        let column: Int
        var id: Self { self }
    }

    @State private var rows: [[String?]] = []
    @State private var page = 0
    @State private var pageEntry = "1"
    @State private var hasNext = false
    @State private var loading = false
    @State private var error: String?
    @State private var selected: Cell?
    @State private var editing: Cell?
    @State private var expanded: Cell?
    @State private var draft = ""
    @State private var null = false
    @State private var pending: Cell?
    @State private var staged: String?
    @State private var filter: DatabaseTableQuery.Filter?
    @State private var filterColumn = 0
    @State private var filterText = ""
    @State private var filterMode = DatabaseTableQuery.FilterMode.exact
    @State private var lastQuery = ""
    @State private var showFilter = false
    @State private var sorting: Int?
    @State private var descending = false
    @State private var hidden = Set<Int>()
    @State private var showInsert = false
    @State private var inputs: [Int: String?] = [:]
    @State private var rowChange: String?
    @State private var deleting = false
    @FocusState private var focused: Bool

    private var visible: [Int] { query.columns.indices.filter { !hidden.contains($0) } }
    private var dirty: Bool { pending != nil || rowChange != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells")
                Text(query.table.displayName).fontWeight(.semibold)
                Divider().frame(height: 14)
                DatabaseToolButton(symbol: "pencil", title: "编辑单元格") { if let selected { start(selected) } }
                    .disabled(selected.map { !editable($0) } ?? true)
                DatabaseToolButton(symbol: "rectangle.expand.vertical", title: "展开字段全文") { if let selected { expand(selected) } }
                    .disabled(selected == nil || dirty || editing != nil)
                Divider().frame(height: 14)
                DatabaseToolButton(symbol: filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill", title: "筛选记录") { showFilter = true }
                    .disabled(navigationLocked)
                    .popover(isPresented: $showFilter) {
                        VStack(alignment: .leading) {
                            Picker("字段", selection: $filterColumn) {
                                ForEach(query.columns.indices, id: \.self) { Text(query.columns[$0].name).tag($0) }
                            }
                            Picker("匹配方式", selection: $filterMode) {
                                Text("精确匹配").tag(DatabaseTableQuery.FilterMode.exact)
                                Text("包含文本").tag(DatabaseTableQuery.FilterMode.contains)
                            }.pickerStyle(.segmented)
                            TextField("字段值", text: $filterText)
                            HStack {
                                Button("清除") { filterText = ""; applyFilter() }
                                Spacer()
                                Button("应用") { applyFilter() }.keyboardShortcut(.defaultAction)
                            }
                        }.padding().frame(width: 260)
                    }
                Menu {
                    ForEach(query.columns.indices, id: \.self) { i in
                        Toggle(query.columns[i].name, isOn: Binding(get: { !hidden.contains(i) }, set: { on in
                            if on { hidden.remove(i) } else if visible.count > 1 { hidden.insert(i) }
                        }))
                    }
                } label: { Image(systemName: "rectangle.split.3x1") }
                .menuStyle(.borderlessButton).fixedSize().help("显示列").disabled(navigationLocked)
                Spacer()
                if readOnly {
                    Text("全局只读已开启")
                    Button("打开设置") { NotificationCenter.default.post(name: .openSettings, object: nil) }
                        .buttonStyle(.link).help("设置 → 数据库 → 所有数据库连接只读")
                } else {
                    Text(query.keys.isEmpty ? "只读 · 无主键，无法定位记录" : "可编辑 · 双击单元格").foregroundStyle(.secondary)
                }
                if loading { ProgressView().controlSize(.small) }
            }
            .disabled(loading)
            .font(.caption).padding(6).background(.ultraThinMaterial)
            Divider()
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(5) }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows.indices, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(visible, id: \.self) { column in
                                    cellView(Cell(row: row, column: column))
                                }
                            }.background(selected?.row == row ? Color.accentColor.opacity(0.12) : Color.primary.opacity(row.isMultiple(of: 2) ? 0 : 0.025))
                        }
                    } header: {
                        HStack(spacing: 0) {
                            ForEach(visible, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 3) {
                                        Text(query.columns[i].name).bold()
                                        if sorting == i { Image(systemName: descending ? "chevron.down" : "chevron.up") }
                                    }
                                    Text(query.columns[i].db_type).foregroundStyle(.secondary)
                                }.lineLimit(1).padding(.horizontal, 6)
                                .frame(width: width(i), height: 38, alignment: .leading)
                                .border(Color.primary.opacity(0.09), width: 0.5)
                                .contentShape(Rectangle()).help("按此列排序")
                                .onTapGesture {
                                    guard !navigationLocked, !loading else { return }
                                    descending = sorting == i && !descending
                                    sorting = i
                                    reloadFromStart()
                                }
                            }
                        }.background(Color(nsColor: .controlBackgroundColor))
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
            .id(page)
            Divider()
            HStack(spacing: 6) {
                DatabaseToolButton(symbol: "plus", title: "新增记录") {
                    inputs = [:]
                    showInsert = true
                }.disabled(readOnly || query.keys.isEmpty || navigationLocked || loading)
                DatabaseToolButton(symbol: "minus", title: "暂存删除所选记录") {
                    if let selected, let sql = query.delete(rows[selected.row]) {
                        rowChange = sql
                        deleting = true
                        navigationLocked = true
                    }
                }.disabled(readOnly || query.keys.isEmpty || selected == nil || navigationLocked || loading)
                Divider().frame(height: 14)
                DatabaseToolButton(symbol: "checkmark", title: "提交修改") { Task { await commit() } }
                    .disabled(!dirty || readOnly || loading)
                DatabaseToolButton(symbol: "xmark", title: "撤销修改") { resetEdit() }
                    .disabled((!dirty && editing == nil) || loading)
                DatabaseToolButton(symbol: "arrow.clockwise", title: "刷新当前页") { Task { await load(page, refreshingFrom: rows.first) } }
                    .disabled(navigationLocked || loading)
                Text(dirty ? (deleting ? "待删除 1 行" : rowChange != nil ? "待新增 1 行" : "1 处待提交") : rows.isEmpty ? "0 条记录" : "\(page * DatabaseTableQuery.pageSize + 1)–\(page * DatabaseTableQuery.pageSize + rows.count) 条记录")
                Text(query.selectSummary)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(lastQuery)
                Spacer(minLength: 0)
                Text("500 条/页").fixedSize()
                DatabaseToolButton(symbol: "backward.end", title: "首页") { Task { await load(0) } }.disabled(page == 0 || navigationLocked || loading)
                DatabaseToolButton(symbol: "chevron.left", title: "上一页") { Task { await load(page - 1, adjacent: true) } }.disabled(page == 0 || navigationLocked || loading)
                TextField("页", text: $pageEntry)
                    .frame(width: 42).multilineTextAlignment(.center)
                    .accessibilityLabel("页码").help("输入页码并按回车")
                    .disabled(navigationLocked || loading)
                    .onSubmit {
                        guard let n = Int(pageEntry), n > 0 else { pageEntry = String(page + 1); return }
                        Task { await load(n - 1, clamp: n - 1 > Int.max / DatabaseTableQuery.pageSize) }
                    }
                DatabaseToolButton(symbol: "chevron.right", title: "下一页") { Task { await load(page + 1, adjacent: true) } }.disabled(!hasNext || navigationLocked || loading)
                DatabaseToolButton(symbol: "forward.end", title: "末页") { Task { await load(page, last: true) } }.disabled(!hasNext || navigationLocked || loading)
            }.font(.caption).padding(6).background(.ultraThinMaterial)
        }
        .task { await load(0) }
        .sheet(isPresented: $showInsert) {
            VStack(alignment: .leading) {
                Text("新增记录 · " + query.table.displayName).font(.headline)
                Text("勾选要填写的字段，其余字段使用数据库默认值。").font(.caption)
                ScrollView {
                    ForEach(query.columns.indices, id: \.self) { i in
                        if query.columns[i].auto_generated != true {
                            HStack {
                                Toggle(query.columns[i].name, isOn: Binding(get: { inputs.keys.contains(i) }, set: { included in
                                    if included {
                                        inputs.updateValue("", forKey: i)
                                    } else {
                                        inputs.removeValue(forKey: i)
                                    }
                                }))
                                    .frame(width: 150, alignment: .leading)
                                TextField(query.columns[i].db_type, text: Binding(get: { inputs[i, default: nil] ?? "" }, set: { inputs[i] = $0 }))
                                    .disabled(inputs[i, default: nil] == nil)
                                if query.columns[i].nullable {
                                    Toggle("NULL", isOn: Binding(get: {
                                        inputs.keys.contains(i) && inputs[i, default: nil] == nil
                                    }, set: { useNull in
                                        inputs.updateValue(useNull ? nil : "", forKey: i)
                                    })).disabled(!inputs.keys.contains(i))
                                }
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("取消") { showInsert = false }
                    Button("暂存新增") {
                        rowChange = query.insert(inputs)
                        navigationLocked = true
                        showInsert = false
                    }.disabled(readOnly)
                }
            }.padding().frame(width: 480, height: 360)
        }
        .sheet(item: $expanded) { cell in
            VStack(alignment: .leading, spacing: 10) {
                Text("\(query.table.displayName) · \(query.columns[cell.column].name)").font(.headline)
                if editable(cell) {
                    TextEditor(text: $draft).font(.system(.body, design: .monospaced)).disabled(null)
                } else {
                    ScrollView { Text(null ? "NULL" : draft).textSelection(.enabled)
                        .font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: .infinity)
                }
                HStack {
                    if editable(cell), query.columns[cell.column].nullable { Toggle("NULL", isOn: $null) }
                    Button("复制全文") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft, forType: .string)
                    }
                    Spacer()
                    Button("关闭") { expanded = nil }
                    if editable(cell) { Button("暂存修改") { stage(cell, value: null ? nil : draft); expanded = nil } }
                }
            }.padding().frame(minWidth: 480, minHeight: 320)
        }
    }

    private func applyFilter() {
        filter = filterText.isEmpty ? nil : DatabaseTableQuery.Filter(column: filterColumn, text: filterText, mode: filterMode)
        showFilter = false
        reloadFromStart()
    }

    private func reloadFromStart() {
        rows = []
        selected = nil
        hasNext = false
        Task { await load(0) }
    }

    private func width(_ column: Int) -> CGFloat {
        let field = query.columns[column]
        if field.primary_key { return 96 }
        if field.db_type.lowercased().contains("text") { return 300 }
        return 170
    }

    private func editable(_ cell: Cell) -> Bool {
        !readOnly && !loading && !dirty && rows.indices.contains(cell.row)
            && query.canEdit(cell.column, row: rows[cell.row])
    }

    private func value(_ cell: Cell) -> String? {
        if pending == cell { return staged }
        return query.value(rows[cell.row][cell.column])
    }

    private func cellView(_ cell: Cell) -> some View {
        let text = value(cell)
        return HStack(spacing: 2) {
            if editing == cell {
                TextField(null ? "NULL" : "", text: Binding(get: { draft }, set: { draft = $0; null = false })).focused($focused)
                    .onAppear { focused = true }.textFieldStyle(.plain)
                    .onSubmit { stage(cell, value: null ? nil : draft) }.onExitCommand { resetEdit() }
                if query.columns[cell.column].nullable {
                    Button("设为 NULL") { stage(cell, value: nil) }
                        .buttonStyle(.borderless).font(.caption).fixedSize()
                }
            } else {
                Text(text ?? "NULL").lineLimit(1).foregroundStyle(text == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                if selected == cell && !dirty && editing == nil {
                    DatabaseToolButton(symbol: "ellipsis", title: "展开全文") { expand(cell) }
                }
            }
        }
        .padding(.horizontal, 6).frame(width: width(cell.column), height: 24, alignment: .leading)
        .border(pending == cell ? Color.orange : selected == cell ? Color.accentColor : Color.primary.opacity(0.09), width: 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { start(cell) }
        .onTapGesture { if editing == nil && !dirty { selected = cell } }
    }

    private func start(_ cell: Cell) {
        guard editable(cell), editing == nil else { return }
        selected = cell
        if (value(cell)?.contains("\n") ?? false) || (value(cell)?.count ?? 0) > 120 {
            expand(cell)
        } else {
            draft = value(cell) ?? ""
            null = value(cell) == nil
            editing = cell
            navigationLocked = true
        }
    }

    private func expand(_ cell: Cell) {
        guard !loading, !dirty, editing == nil else { return }
        draft = value(cell) ?? ""
        null = value(cell) == nil
        expanded = cell
    }

    private func stage(_ cell: Cell, value newValue: String?) {
        editing = nil
        if newValue != value(cell) && editable(cell) {
            pending = cell
            staged = newValue
        }
        navigationLocked = pending != nil
    }

    private func resetEdit() {
        editing = nil
        rowChange = nil
        deleting = false
        pending = nil
        staged = nil
        navigationLocked = false
    }

    @MainActor private func commit() async {
        guard !loading, !readOnly else { return }
        let update = pending.flatMap { query.update($0.column, row: rows[$0.row], newValue: staged) }
        guard let sql = rowChange ?? update else { return }
        loading = true
        do {
            let result = try await execute(sql, false)
            guard result.affected_rows == 1 else {
                error = "记录已变化或写入未生效。请撤销修改并刷新。"
                loading = false
                return
            }
            let boundary = rows.first
            resetEdit()
            selected = nil
            rows = []
            loading = false
            await load(page, refreshingFrom: boundary)
        } catch { self.error = error.localizedDescription; loading = false }
    }

    @MainActor private func load(_ target: Int, last: Bool = false, clamp: Bool = false, adjacent: Bool = false, refreshingFrom: [String?]? = nil) async {
        guard !loading, target >= 0 else { return }
        loading = true
        defer { loading = false }
        do {
            var index = target
            var tailCount: Int?
            if last || clamp {
                let count = try await execute(query.count(filter), true)
                guard let raw = count.rows.first?.first ?? nil, let total = Int(raw) else { throw CocoaError(.coderReadCorrupt) }
                let end = max(0, total - 1) / DatabaseTableQuery.pageSize
                index = last ? end : min(target, end)
                if index == end && end > 0 { tailCount = total }
            }
            var reverse = false
            let sql: String
            if let tailCount {
                sql = query.tailPage(count: tailCount, filter: filter, sorting: sorting, descending: descending)
                reverse = true
            } else if index > 0, let refreshingFrom, let refresh = query.adjacentPage(from: refreshingFrom,
                        backwards: false, filter: filter, sorting: sorting, descending: descending, includingBoundary: true) {
                sql = refresh
            } else if adjacent, let boundary = target < page ? rows.first : rows.last,
                      let seek = query.adjacentPage(from: boundary, backwards: target < page, filter: filter,
                                                    sorting: sorting, descending: descending) {
                reverse = target < page
                sql = seek
            } else {
                sql = query.page(index, filter: filter, sorting: sorting, descending: descending)
            }
            let result = try await execute(sql, true)
            try Task.checkCancellation()
            guard result.rows.allSatisfy({ $0.count == query.columns.count }) else { throw CocoaError(.coderReadCorrupt) }
            let slice = result.rows.prefix(DatabaseTableQuery.pageSize)
            if !clamp && !last && index > 0 && slice.isEmpty {
                loading = false
                await load(target, clamp: true)
                return
            }
            rows = reverse ? Array(slice.reversed()) : Array(slice)
            hasNext = tailCount == nil && (reverse || result.rows.count > DatabaseTableQuery.pageSize)
            page = index
            pageEntry = String(index + 1)
            lastQuery = sql
            selected = nil
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
