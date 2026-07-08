import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DatabaseBackupSheet: View {
    let appState: AppState
    let initialTargetConnectionId: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inventoryState: InventoryState

    @State private var backupPath: String = ""
    @State private var targetConnectionId: String = ""
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560)
        .onAppear(perform: applyInitialSelection)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.counterclockwise.icloud")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 30, height: 30)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text("恢复数据库备份")
                    .font(.system(size: 15, weight: .semibold))
                Text("选择 .orbit-db-backup.json 并恢复到目标连接")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("备份文件") {
                HStack(spacing: 8) {
                    TextField("选择 .orbit-db-backup.json", text: $backupPath)
                        .textFieldStyle(.roundedBorder)
                    Button(action: selectBackupFile) {
                        Image(systemName: "folder")
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("选择备份文件")
                }
            }

            section("目标连接") {
                Picker("", selection: $targetConnectionId) {
                    Text("选择目标数据库").tag("")
                    ForEach(inventoryState.databaseConnections) { connection in
                        Text("\(connection.name) · \(connection.engineLabel)").tag(connection.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let resultMessage {
                messageView(resultMessage, color: .green, icon: "checkmark.circle")
            }

            if let errorMessage {
                messageView(errorMessage, color: .red, icon: "exclamationmark.triangle")
            }
        }
        .padding(16)
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

            Button("恢复") {
                Task { await restoreBackup() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRestore || inventoryState.databaseOperationLoading)
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

    private func messageView(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var canRestore: Bool {
        isBackupPathValid && !targetConnectionId.isEmpty
    }

    private var isBackupPathValid: Bool {
        backupPath.hasSuffix(".orbit-db-backup.json")
    }

    private func applyInitialSelection() {
        if targetConnectionId.isEmpty {
            targetConnectionId = initialTargetConnectionId ?? inventoryState.databaseConnections.first?.id ?? ""
        }
    }

    private func selectBackupFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.message = "选择 .orbit-db-backup.json 备份文件"
        if panel.runModal() == .OK, let url = panel.url {
            if url.path.hasSuffix(".orbit-db-backup.json") {
                backupPath = url.path
                errorMessage = nil
            } else {
                errorMessage = "请选择 .orbit-db-backup.json 文件"
            }
        }
    }

    @MainActor
    private func restoreBackup() async {
        guard canRestore else { return }
        resultMessage = nil
        errorMessage = nil
        do {
            let request = DatabaseRestoreRequest(
                backup_path: backupPath,
                target_connection_id: targetConnectionId,
                mode: "overwrite"
            )
            let result = try await appState.restoreDatabaseBackup(request: request)
            resultMessage = appState.databaseOperationMessage(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension DatabaseConnection {
    var engineLabel: String {
        switch engine {
        case "remote_sqlite": return "Remote SQLite"
        case "mysql": return "MySQL"
        case "postgres": return "PostgreSQL"
        default: return engine
        }
    }
}
