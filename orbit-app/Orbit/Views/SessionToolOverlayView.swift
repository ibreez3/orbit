import SwiftUI

struct SessionToolOverlayView: View {
    let appState: AppState
    @EnvironmentObject private var toolState: ToolState
    @EnvironmentObject private var inventoryState: InventoryState

    var body: some View {
        if let state = toolState.activeTool, state.tool != .ai {
            FloatingToolCard(
                title: title(for: state.tool),
                subtitle: subtitle(for: state.boundContext),
                onPin: {},
                onExpand: { expand(state.tool, context: state.boundContext) },
                onClose: { appState.closeOverlayTool() }
            ) {
                content(for: state)
            }
            .padding(.top, 14)
            .padding(.trailing, 14)
            .transition(.scale(scale: 0.98).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func content(for state: BoundToolState) -> some View {
        switch state.tool {
        case .sftp:
            SftpQuickOverlay(appState: appState, context: state.boundContext)
        case .monitor:
            MonitorQuickOverlay(appState: appState, context: state.boundContext)
        case .logs:
            LogsQuickOverlay(context: state.boundContext)
        case .snippets:
            SnippetsQuickOverlay(appState: appState, context: state.boundContext)
        case .ai:
            EmptyView()
        }
    }

    private func title(for tool: SessionTool) -> String {
        switch tool {
        case .ai:
            return "AI"
        case .sftp:
            return "SFTP"
        case .monitor:
            return "Monitor"
        case .logs:
            return "Logs"
        case .snippets:
            return "Snippets"
        }
    }

    private func subtitle(for context: ActiveSessionContext) -> String {
        context.serverName ?? "No active session"
    }

    private func expand(_ tool: SessionTool, context: ActiveSessionContext) {
        switch tool {
        case .sftp:
            if let serverId = context.serverId,
               let server = inventoryState.servers.first(where: { $0.id == serverId }) {
                appState.addTab(server: server, type: .sftp)
                appState.closeOverlayTool()
            }
        case .monitor:
            if let serverId = context.serverId,
               let server = inventoryState.servers.first(where: { $0.id == serverId }) {
                appState.addTab(server: server, type: .monitor)
                appState.closeOverlayTool()
            }
        default:
            break
        }
    }
}

private struct SftpQuickOverlay: View {
    let appState: AppState
    @State private var path = ""
    @State private var pathHistory: [String] = []
    @State private var entries: [FileEntry] = []
    @State private var selectedEntry: FileEntry?
    @State private var loading = false
    @State private var error: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var transfer: SftpQuickTransfer?
    @State private var transferTask: Task<Void, Never>?
    let context: ActiveSessionContext

    private struct SftpQuickTransfer {
        let direction: String
        let fileName: String
        var transferred: UInt64
        var total: UInt64
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("文件传输")
                        .font(.system(size: 12, weight: .semibold))
                    Text(path.isEmpty ? (context.serverName ?? "No active session") : path)
                        .font(.system(size: 10, design: path.isEmpty ? .default : .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .rotationEffect(.degrees(loading ? 360 : 0))
                        .animation(loading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: loading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(context.serverId == nil || loading)
                .help("刷新目录")
            }

            if context.serverId == nil {
                sftpEmptyState("当前没有可用的 SSH 会话")
            } else if loading && entries.isEmpty {
                sftpLoadingState
            } else if let error, entries.isEmpty {
                sftpErrorState(error)
            } else {
                sftpContent
            }

            if let transfer {
                transferProgress(transfer)
            }
        }
        .padding(12)
        .onAppear(perform: loadInitialDirectory)
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
            transferTask?.cancel()
            transferTask = nil
            clearProgressHandler()
        }
    }

    private func loadInitialDirectory() {
        guard path.isEmpty else {
            refresh()
            return
        }
        refresh()
    }

    private func refresh() {
        guard let serverId = context.serverId else { return }
        let bridge = appState.bridge
        refreshTask?.cancel()
        loading = true
        error = nil

        refreshTask = Task {
            do {
                let targetPath = path.isEmpty ? ((try? await Task.detached {
                    try bridge.getServerHome(serverId: serverId)
                }.value) ?? "/") : path
                let result = try await Task.detached {
                    try bridge.sftpListFull(serverId: serverId, path: targetPath)
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    path = targetPath
                    if pathHistory.isEmpty { pathHistory = [targetPath] }
                    entries = sortedEntries(result)
                    selectedEntry = nil
                    loading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.error = "加载目录失败: \(error.localizedDescription)"
                    loading = false
                }
            }
        }
    }

    private var sftpContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            actionBar

            HStack(spacing: 8) {
                sftpStatCard("目录", value: "\(directoryCount)", icon: "folder", tint: .yellow)
                sftpStatCard("文件", value: "\(fileCount)", icon: "doc", tint: .blue)
                sftpStatCard("大小", value: formatSize(totalFileSize), icon: "externaldrive", tint: .secondary)
            }

            if let error {
                compactWarning(error)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("远端目录")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if let selectedEntry {
                        Text(selectedEntry.is_dir ? "进入: \(selectedEntry.name)" : "已选: \(selectedEntry.name)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if entries.isEmpty {
                    Text("当前目录为空")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 18)
                } else {
                    ForEach(entries.prefix(7)) { entry in
                        sftpEntryRow(entry)
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: goBack) {
                Image(systemName: "arrow.left")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(pathHistory.count <= 1 || loading || transfer != nil)
            .help("返回上一级")

            Button(action: uploadFile) {
                Label("上传", systemImage: "arrow.up.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(context.serverId == nil || path.isEmpty || loading || transfer != nil)
            .help("上传到当前远端目录")

            Button(action: downloadSelectedFile) {
                Label("下载", systemImage: "arrow.down.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(selectedEntry == nil || selectedEntry?.is_dir == true || loading || transfer != nil)
            .help("下载选中的远端文件")

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sftpStatCard(_ title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sftpEntryRow(_ entry: FileEntry) -> some View {
        let selected = selectedEntry?.path == entry.path
        return HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : (entry.is_dir ? "chevron.right.circle" : "circle"))
                .font(.system(size: 10))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: 14)
            Image(systemName: entry.is_dir ? "folder.fill" : entryIcon(entry))
                .font(.system(size: 11))
                .foregroundStyle(entry.is_dir ? .yellow : .secondary)
                .frame(width: 16)
            Text(entry.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(entry.is_dir ? "-" : formatSize(entry.size))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.is_dir {
                openDirectory(entry)
            } else {
                selectedEntry = entry
            }
        }
    }

    private func compactWarning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var sftpLoadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
            Text("正在读取远端 Home 目录...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func sftpEmptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func sftpErrorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                refresh()
            }
            .buttonStyle(.borderless)
            .disabled(context.serverId == nil || loading)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func transferProgress(_ transfer: SftpQuickTransfer) -> some View {
        let percent = transfer.total > 0 ? min(Double(transfer.transferred) / Double(transfer.total), 1) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(transfer.direction): \(transfer.fileName)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(formatSize(transfer.transferred)) / \(transfer.total > 0 ? formatSize(transfer.total) : "...")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            ProgressView(value: percent)
                .scaleEffect(y: 1.2, anchor: .center)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func openDirectory(_ entry: FileEntry) {
        guard entry.is_dir, transfer == nil else { return }
        pathHistory.append(entry.path)
        path = entry.path
        refresh()
    }

    private func goBack() {
        guard pathHistory.count > 1, transfer == nil else { return }
        pathHistory.removeLast()
        path = pathHistory.last ?? "/"
        refresh()
    }

    private func uploadFile() {
        guard let serverId = context.serverId, transfer == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let fileName = url.lastPathComponent
            let remotePath = path == "/" ? "/\(fileName)" : "\(path)/\(fileName)"
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            startTransfer(direction: "上传", fileName: fileName, total: fileSize)
            let bridge = appState.bridge
            transferTask = Task {
                do {
                    try await Task.detached {
                        try bridge.sftpUpload(serverId: serverId, localPath: url.path, remotePath: remotePath)
                    }.value
                    await MainActor.run {
                        finishTransfer()
                        refresh()
                        appendSftpAudit(action: "upload", target: remotePath, result: .succeeded, summary: "上传文件 \(fileName)")
                    }
                } catch {
                    await MainActor.run {
                        failTransfer("上传失败: \(error.localizedDescription)")
                        appendSftpAudit(action: "upload", target: remotePath, result: .failed, summary: "上传文件失败 \(fileName)")
                    }
                }
            }
        }
    }

    private func downloadSelectedFile() {
        guard let serverId = context.serverId,
              let entry = selectedEntry,
              !entry.is_dir,
              transfer == nil else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            startTransfer(direction: "下载", fileName: entry.name, total: entry.size)
            let bridge = appState.bridge
            transferTask = Task {
                do {
                    try await Task.detached {
                        try bridge.sftpDownload(serverId: serverId, remotePath: entry.path, localPath: url.path)
                    }.value
                    await MainActor.run {
                        finishTransfer()
                        appendSftpAudit(action: "download", target: entry.path, result: .succeeded, summary: "下载文件 \(entry.name)")
                    }
                } catch {
                    await MainActor.run {
                        failTransfer("下载失败: \(error.localizedDescription)")
                        appendSftpAudit(action: "download", target: entry.path, result: .failed, summary: "下载文件失败 \(entry.name)")
                    }
                }
            }
        }
    }

    private func startTransfer(direction: String, fileName: String, total: UInt64) {
        guard let serverId = context.serverId else { return }
        transfer = SftpQuickTransfer(direction: direction, fileName: fileName, transferred: 0, total: total)
        if let tabId = context.tabId {
            appState.setSftpTransferActive(true, for: tabId)
        }
        OrbitBridge.shared.handlersLock.lock()
        OrbitBridge.shared.progressHandlers[serverId] = { transferred, total in
            DispatchQueue.main.async {
                self.transfer?.transferred = transferred
                self.transfer?.total = total
            }
        }
        OrbitBridge.shared.handlersLock.unlock()
    }

    private func finishTransfer() {
        if let tabId = context.tabId {
            appState.setSftpTransferActive(false, for: tabId)
        }
        transfer = nil
        transferTask = nil
        clearProgressHandler()
    }

    private func failTransfer(_ message: String) {
        error = message
        finishTransfer()
    }

    private func clearProgressHandler() {
        guard let serverId = context.serverId else { return }
        OrbitBridge.shared.handlersLock.lock()
        OrbitBridge.shared.progressHandlers.removeValue(forKey: serverId)
        OrbitBridge.shared.handlersLock.unlock()
    }

    private func appendSftpAudit(action: String, target: String, result: AuditResult, summary: String) {
        appState.appendAuditEvent(category: .sftp, action: action, target: target, result: result, summary: summary)
    }

    private func sortedEntries(_ input: [FileEntry]) -> [FileEntry] {
        input.sorted { lhs, rhs in
            if lhs.is_dir != rhs.is_dir { return lhs.is_dir && !rhs.is_dir }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var directoryCount: Int {
        entries.filter(\.is_dir).count
    }

    private var fileCount: Int {
        entries.count - directoryCount
    }

    private var totalFileSize: UInt64 {
        entries.filter { !$0.is_dir }.reduce(UInt64(0)) { $0 + $1.size }
    }

    private func entryIcon(_ entry: FileEntry) -> String {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let textExts: Set<String> = ["txt", "md", "json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "log", "csv", "html", "htm", "css", "js", "ts", "py", "rb", "go", "rs", "java", "c", "cpp", "h", "hpp", "sh", "bash", "zsh", "fish", "sql", "env"]
        return textExts.contains(ext) ? "doc.text" : "doc"
    }
}

private struct MonitorQuickOverlay: View {
    let appState: AppState
    @State private var stats: ServerStats?
    @State private var loading = false
    @State private var error: String?
    @State private var refreshTask: Task<Void, Never>?
    let context: ActiveSessionContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时快照")
                        .font(.system(size: 12, weight: .semibold))
                    Text(context.serverName ?? "No active session")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .rotationEffect(.degrees(loading ? 360 : 0))
                        .animation(loading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: loading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(context.serverId == nil || loading)
                .help("刷新监控数据")
            }

            if context.serverId == nil {
                emptyState("当前没有可监控的 SSH 会话")
            } else if let error, hasNoUsableStats {
                errorState(error)
            } else if let stats {
                statsContent(stats)
            } else if let error {
                errorState(error)
            } else {
                loadingState
            }

            Spacer()
        }
        .padding(12)
        .onAppear(perform: start)
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private func start() {
        refresh()
    }

    private func refresh() {
        guard let serverId = context.serverId else { return }
        refreshTask?.cancel()
        loading = true
        error = nil

        refreshTask = Task {
            do {
                let result = try await appState.bridge.getServerStatsAsync(serverId: serverId)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    stats = result
                    loading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.error = "获取监控数据失败: \(error.localizedDescription)"
                    loading = false
                }
            }
        }
    }

    @ViewBuilder
    private func statsContent(_ stats: ServerStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                compactMetric("CPU", value: percentage(stats.cpu_usage), icon: "cpu", tint: .cyan, progress: stats.cpu_usage)
                compactMetric("内存", value: percentage(stats.mem_percent), icon: "memorychip", tint: .purple, progress: stats.mem_percent)
            }

            HStack(spacing: 8) {
                compactMetric("磁盘", value: percentage(stats.disk_percent), icon: "harddrive", tint: .yellow, progress: stats.disk_percent)
                compactInfo("负载", value: stats.load_avg.isEmpty ? "N/A" : stats.load_avg, icon: "waveform.path.ecg")
            }

            networkCard(stats)

            VStack(alignment: .leading, spacing: 6) {
                infoLine("内存", "\(formatMB(stats.mem_used_mb)) / \(formatMB(stats.mem_total_mb))")
                infoLine("磁盘", "\(stats.disk_used) / \(stats.disk_total)")
                infoLine("运行时间", stats.uptime.isEmpty ? "N/A" : stats.uptime)
            }

            if let error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func compactMetric(_ title: String, value: String, icon: String, tint: Color, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            ProgressView(value: clamped(progress) / 100)
                .tint(tint)
                .scaleEffect(y: 1.2, anchor: .center)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func compactInfo(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func networkCard(_ stats: ServerStats) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.arrow.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("网络")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let iface = stats.net_interface, !iface.isEmpty {
                        Text(iface)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 14) {
                    Text("↓ \(formatRate(stats.net_rx_kbps))")
                    Text("↑ \(formatRate(stats.net_tx_kbps))")
                }
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
            Text("正在获取 CPU、内存、磁盘和负载数据...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                refresh()
            }
            .buttonStyle(.borderless)
            .disabled(context.serverId == nil || loading)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private func formatMB(_ mb: UInt64) -> String {
        if mb >= 1024 { return String(format: "%.1fG", Double(mb) / 1024.0) }
        return "\(mb)M"
    }

    private func formatRate(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        if value >= 1024 {
            return String(format: "%.1f MB/s", value / 1024.0)
        }
        return String(format: "%.1f KB/s", value)
    }

    private var hasNoUsableStats: Bool {
        guard let stats else { return true }
        return stats.mem_total_mb == 0 &&
            stats.disk_total.isEmpty &&
            stats.disk_used.isEmpty &&
            stats.uptime.isEmpty &&
            stats.load_avg.isEmpty
    }
}

private struct LogsQuickOverlay: View {
    @EnvironmentObject private var aiState: AIState
    let context: ActiveSessionContext

    var body: some View {
        let events = aiState.auditEventsByContext[context.identity] ?? []
        let recentEvents = Array(events.suffix(8).reversed())

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("审计日志")
                        .font(.system(size: 12, weight: .semibold))
                    Text("开启")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(context.serverName ?? "No active session")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                logStatCard("总数", value: "\(events.count)", tint: .blue)
                logStatCard("成功", value: "\(events.filter { $0.result == .succeeded }.count)", tint: .green)
                logStatCard("失败", value: "\(events.filter { $0.result == .failed }.count)", tint: .red)
            }

            if recentEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("当前会话还没有审计事件")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近事件")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(recentEvents) { event in
                        logEventRow(event)
                    }
                }
            }

            Spacer()
        }
        .padding(12)
    }

    private func logStatCard(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func logEventRow(_ event: AuditEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(resultColor(event.result))
                    .frame(width: 6, height: 6)
                Text(categoryTitle(event.category))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(resultTitle(event.result))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(resultColor(event.result))
                Spacer(minLength: 0)
                Text(Self.timeFormatter.string(from: event.timestamp))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text(event.summary)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let target = event.target, !target.isEmpty {
                Text(target)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func categoryTitle(_ category: AuditCategory) -> String {
        switch category {
        case .connection: return "连接"
        case .terminalCommand: return "命令"
        case .aiAction: return "AI"
        case .sftp: return "SFTP"
        case .monitor: return "监控"
        case .database: return "数据库"
        case .tool: return "工具"
        case .error: return "错误"
        }
    }

    private func resultTitle(_ result: AuditResult) -> String {
        switch result {
        case .requested: return "请求"
        case .authorized: return "授权"
        case .denied: return "拒绝"
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .canceled: return "取消"
        }
    }

    private func resultColor(_ result: AuditResult) -> Color {
        switch result {
        case .succeeded, .authorized:
            return .green
        case .failed, .denied:
            return .red
        case .canceled:
            return .orange
        case .requested:
            return .blue
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct SnippetsQuickOverlay: View {
    let appState: AppState
    @EnvironmentObject private var snippetState: SnippetState
    let context: ActiveSessionContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Command snippets")
                .font(.system(size: 12, weight: .semibold))

            if snippetState.snippets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("暂无命令片段")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button("新建片段") {
                        appState.openSnippetEditor()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } else {
                ForEach(snippetState.snippets.prefix(6)) { snippet in
                    Button(action: { insert(snippet.command) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snippet.name)
                                    .font(.system(size: 11, weight: .medium))
                                Text(snippet.command)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("插入到终端") { insert(snippet.command) }
                        Button("编辑") { appState.openSnippetEditor(snippet: snippet) }
                        Button("删除", role: .destructive) { appState.deleteSnippet(snippet.id) }
                    }
                }
            }

            Spacer()
        }
        .padding(12)
    }

    private func insert(_ command: String) {
        if let sessionId = context.sessionId,
           let terminalView = OrbitBridge.shared.terminalView(for: sessionId) as? OrbitTerminalView {
            appState.insertSnippetCommand(command, into: terminalView)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }
}
