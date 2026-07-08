import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DatabaseImportMappingView: View {
    let appState: AppState
    let initialTargetConnectionId: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inventoryState: InventoryState

    @State private var backupPath: String = ""
    @State private var targetConnectionId: String = ""
    @State private var mode: String = "existing_table"
    @State private var plan: DatabaseImportPlan?
    @State private var resultSummary: ImportRunSummary?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 820, height: 640)
        .onAppear(perform: applyInitialSelection)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 30, height: 30)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text("SQLite 导入 MySQL")
                    .font(.system(size: 15, weight: .semibold))
                Text("编辑目标表与字段映射")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
    }

    private var content: some View {
        VStack(spacing: 0) {
            importControls
            Divider()
            mappingContent
        }
    }

    private var importControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("选择 .orbit-db-backup.json", text: $backupPath)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: backupPath) { _ in clearPreparedPlan() }

                Button(action: selectBackupFile) {
                    Image(systemName: "folder")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .help("选择备份文件")
            }

            HStack(spacing: 12) {
                Picker("", selection: $targetConnectionId) {
                    Text("选择 MySQL 目标").tag("")
                    ForEach(mysqlConnections) { connection in
                        Text(connection.name).tag(connection.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220, alignment: .leading)
                .onChange(of: targetConnectionId) { _ in clearPreparedPlan() }

                Picker("", selection: $mode) {
                    Text("导入已有表").tag("existing_table")
                    Text("创建新表").tag("new_table")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: mode) { _ in clearPreparedPlan() }

                Spacer()

                Button(action: { Task { await prepareImportPlan() } }) {
                    Label("生成映射", systemImage: "wand.and.stars")
                }
                .disabled(!canPrepare || inventoryState.databaseOperationLoading)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let resultSummary {
                importSummaryView(resultSummary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var mappingContent: some View {
        if inventoryState.databaseOperationLoading && plan == nil {
            ProgressView("生成导入映射…")
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plan {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.tables.indices, id: \.self) { tableIndex in
                        tableMappingView(tableIndex)
                    }
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tablecells.badge.ellipsis")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("生成映射后编辑表和字段")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tableMappingView(_ tableIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(plan?.tables[safe: tableIndex]?.source_table ?? "")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("目标表", text: targetTableBinding(tableIndex))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 220)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    columnHeader("来源字段")
                    columnHeader("目标字段")
                    columnHeader("目标类型")
                    columnHeader("约束")
                }

                ForEach(columnIndices(for: tableIndex), id: \.self) { columnIndex in
                    GridRow {
                        sourceColumnField(tableIndex: tableIndex, columnIndex: columnIndex)
                        targetColumnField(tableIndex: tableIndex, columnIndex: columnIndex)
                        Text(plan?.tables[safe: tableIndex]?.columns[safe: columnIndex]?.target_type ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 120, alignment: .leading)
                        requiredLabel(tableIndex: tableIndex, columnIndex: columnIndex)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func sourceColumnField(tableIndex: Int, columnIndex: Int) -> some View {
        TextField("来源字段", text: sourceColumnBinding(tableIndex: tableIndex, columnIndex: columnIndex))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 210)
    }

    private func targetColumnField(tableIndex: Int, columnIndex: Int) -> some View {
        TextField("跳过", text: targetColumnBinding(tableIndex: tableIndex, columnIndex: columnIndex))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 210)
    }

    private func requiredLabel(tableIndex: Int, columnIndex: Int) -> some View {
        let required = plan?.tables[safe: tableIndex]?.columns[safe: columnIndex]?.required_without_default ?? false
        return Text(required ? "必填" : "可选")
            .font(.system(size: 11))
            .foregroundStyle(required ? Color.orange : Color.secondary)
            .frame(width: 60, alignment: .leading)
    }

    private func columnHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if inventoryState.databaseOperationLoading {
                ProgressView()
                    .scaleEffect(0.75)
            }
            Spacer()
            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("运行导入") {
                Task { await runImport() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRunImport || inventoryState.databaseOperationLoading)
        }
        .padding(16)
    }

    private func importSummaryView(_ summary: ImportRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(summary.ok ? "导入完成" : "导入失败", systemImage: summary.ok ? "checkmark.circle" : "xmark.octagon")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(summary.ok ? Color.green : Color.red)
            Text("表 \(summary.tableCount)，行 \(summary.rowCount)，跳过字段 \(summary.skippedFieldCount)")
                .font(.system(size: 12))
            if !summary.errorSummary.isEmpty {
                Text(summary.errorSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(summary.ok ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((summary.ok ? Color.green : Color.red).opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var mysqlConnections: [DatabaseConnection] {
        inventoryState.databaseConnections.filter { $0.engine == "mysql" }
    }

    private var canPrepare: Bool {
        backupPath.hasSuffix(".orbit-db-backup.json") && !targetConnectionId.isEmpty
    }

    private var canRunImport: Bool {
        plan != nil && validationMessage == nil
    }

    private func columnIndices(for tableIndex: Int) -> [Int] {
        guard let columns = plan?.tables[safe: tableIndex]?.columns else { return [] }
        return Array(columns.indices)
    }

    private var validationMessage: String? {
        guard let plan else { return nil }
        for table in plan.tables {
            let targetTable = trimmed(table.target_table)
            for column in table.columns where column.required_without_default {
                let sourceColumn = trimmed(column.source_column)
                let targetColumn = trimmed(column.target_column ?? "")
                if sourceColumn.isEmpty || targetColumn.isEmpty {
                    let fieldName = targetColumn.isEmpty ? sourceColumn : targetColumn
                    return "目标表 \(targetTable) 的字段 \(fieldName) 缺少来源映射或默认值"
                }
            }
        }
        return nil
    }

    private func targetTableBinding(_ tableIndex: Int) -> Binding<String> {
        Binding(
            get: { plan?.tables[safe: tableIndex]?.target_table ?? "" },
            set: { newValue in
                guard var currentPlan = plan, currentPlan.tables.indices.contains(tableIndex) else { return }
                currentPlan.tables[tableIndex].target_table = newValue
                plan = currentPlan
            }
        )
    }

    private func sourceColumnBinding(tableIndex: Int, columnIndex: Int) -> Binding<String> {
        Binding(
            get: { plan?.tables[safe: tableIndex]?.columns[safe: columnIndex]?.source_column ?? "" },
            set: { newValue in
                guard var currentPlan = plan,
                      currentPlan.tables.indices.contains(tableIndex),
                      currentPlan.tables[tableIndex].columns.indices.contains(columnIndex) else { return }
                currentPlan.tables[tableIndex].columns[columnIndex].source_column = newValue
                plan = currentPlan
            }
        )
    }

    private func targetColumnBinding(tableIndex: Int, columnIndex: Int) -> Binding<String> {
        Binding(
            get: { plan?.tables[safe: tableIndex]?.columns[safe: columnIndex]?.target_column ?? "" },
            set: { newValue in
                guard var currentPlan = plan,
                      currentPlan.tables.indices.contains(tableIndex),
                      currentPlan.tables[tableIndex].columns.indices.contains(columnIndex) else { return }
                currentPlan.tables[tableIndex].columns[columnIndex].target_column = trimmed(newValue).isEmpty ? nil : newValue
                plan = currentPlan
            }
        )
    }

    private func applyInitialSelection() {
        if targetConnectionId.isEmpty {
            if let initialTargetConnectionId,
               mysqlConnections.contains(where: { $0.id == initialTargetConnectionId }) {
                targetConnectionId = initialTargetConnectionId
            } else {
                targetConnectionId = mysqlConnections.first?.id ?? ""
            }
        }
    }

    private func clearPreparedPlan() {
        plan = nil
        resultSummary = nil
        errorMessage = nil
    }

    private func selectBackupFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.message = "选择 SQLite .orbit-db-backup.json 备份文件"
        if panel.runModal() == .OK, let url = panel.url {
            if url.path.hasSuffix(".orbit-db-backup.json") {
                backupPath = url.path
                clearPreparedPlan()
            } else {
                errorMessage = "请选择 .orbit-db-backup.json 文件"
            }
        }
    }

    @MainActor
    private func prepareImportPlan() async {
        guard canPrepare else { return }
        errorMessage = nil
        resultSummary = nil
        do {
            plan = try await appState.prepareDatabaseImport(
                backupPath: backupPath,
                targetConnectionId: targetConnectionId,
                mode: mode
            )
        } catch {
            plan = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runImport() async {
        guard var importPlan = plan, validationMessage == nil else { return }
        importPlan.backup_path = backupPath
        importPlan.target_connection_id = targetConnectionId
        importPlan.mode = mode
        errorMessage = nil
        do {
            let skipped = skippedFieldCount(in: importPlan)
            let result = try await appState.runDatabaseImport(request: DatabaseImportRequest(plan: importPlan))
            resultSummary = ImportRunSummary(
                ok: result.ok,
                tableCount: importPlan.tables.count,
                rowCount: result.affected_rows ?? 0,
                skippedFieldCount: skipped,
                errorSummary: result.ok ? result.message : appState.databaseOperationMessage(result)
            )
            plan = importPlan
        } catch {
            resultSummary = ImportRunSummary(
                ok: false,
                tableCount: importPlan.tables.count,
                rowCount: 0,
                skippedFieldCount: skippedFieldCount(in: importPlan),
                errorSummary: error.localizedDescription
            )
        }
    }

    private func skippedFieldCount(in plan: DatabaseImportPlan) -> Int {
        plan.tables.reduce(0) { partial, table in
            partial + table.columns.filter {
                trimmed($0.source_column).isEmpty || trimmed($0.target_column ?? "").isEmpty
            }.count
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ImportRunSummary {
    let ok: Bool
    let tableCount: Int
    let rowCount: UInt64
    let skippedFieldCount: Int
    let errorSummary: String
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
