import SwiftUI

struct SftpView: View {
    let tab: TabItem
    @Environment(AppState.self) var appState
    @State private var path: String = ""
    @State private var entries: [FileEntry] = []
    @State private var loading: Bool = false
    @State private var selectedEntry: FileEntry?
    @State private var lastClickTime: Date = .distantPast
    @State private var lastClickPath: String = ""
    @State private var pathHistory: [String] = []
    @State private var transfer: TransferInfo?
    @State private var showMkdirAlert = false
    @State private var mkdirName = ""

    struct TransferInfo {
        let direction: String
        let fileName: String
        var transferred: UInt64
        var total: UInt64
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            fileTable
            if transfer != nil {
                progressBar
            }
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadHome() }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: goBack) {
                Image(systemName: "arrow.left")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("返回")

            Button(action: { loadDir(path) }) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("刷新")

            Button(action: { navigateTo("/") }) {
                Image(systemName: "house")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("根目录")

            pathBreadcrumb

            Spacer()

            Button(action: handleDownload) {
                Image(systemName: "arrow.down.to.line")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(selectedEntry == nil || selectedEntry!.is_dir || transfer != nil)
            .help("下载")

            Button(action: handleUpload) {
                Image(systemName: "arrow.up.to.line")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(transfer != nil)
            .help("上传")

            Button(action: { showMkdirAlert = true }) {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("新建文件夹")

            Button(action: handleDelete) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selectedEntry != nil ? .red : .secondary)
            .disabled(selectedEntry == nil)
            .help("删除")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var pathBreadcrumb: some View {
        let segments = path.split(separator: "/").map(String.init)
        return HStack(spacing: 2) {
            ForEach(0..<segments.count, id: \.self) { i in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Button(segments[i]) {
                    let target = "/" + segments[0...i].joined(separator: "/")
                    navigateTo(target)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(4)
    }

    private var fileTable: some View {
        Group {
            if loading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            row(for: entry)
                        }
                    }
                }
            }
        }
    }

    private func row(for entry: FileEntry) -> some View {
        let isSelected = selectedEntry?.path == entry.path
        return HStack(spacing: 8) {
            Button {
                selectOrNavigate(entry: entry)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)

            Image(systemName: entry.is_dir ? "folder.fill" : "doc")
                .foregroundStyle(entry.is_dir ? .yellow : .secondary)
                .font(.system(size: 13))
                .frame(width: 20)

            Text(entry.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.is_dir ? "-" : formatSize(entry.size))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(entry.modified)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)

            Text(entry.permissions)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .onTapGesture {
            selectOrNavigate(entry: entry)
        }
    }

    private func selectOrNavigate(entry: FileEntry) {
        let now = Date()
        let isDoubleClick = now.timeIntervalSince(lastClickTime) < 0.4 && lastClickPath == entry.path
        lastClickTime = now
        lastClickPath = entry.path

        if isDoubleClick && entry.is_dir {
            navigateTo(entry.path)
            return
        }

        if selectedEntry?.path == entry.path {
            selectedEntry = nil
        } else {
            selectedEntry = entry
        }
    }

    private var progressBar: some View {
        let pct = transfer.map { t in
            t.total > 0 ? Int(Double(t.transferred) / Double(t.total) * 100) : 0
        } ?? 0
        return VStack(spacing: 4) {
            HStack {
                Text("\(transfer?.direction == "download" ? "下载" : "上传"): \(transfer?.fileName ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(formatSize(transfer?.transferred ?? 0)) / \(transfer.map { $0.total > 0 ? formatSize($0.total) : "..." } ?? "")\(pct > 0 ? " (\(pct)%)" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(pct), total: 100)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusBar: some View {
        HStack {
            Text("\(entries.count) 项")
            if let sel = selectedEntry {
                Text("已选: \(sel.name)")
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func loadHome() {
        blockingAsync {
            do {
                let home = try self.appState.bridge.getServerHome(serverId: self.tab.serverId)
                DispatchQueue.main.async {
                    self.pathHistory = [home]
                    self.loadDir(home)
                }
            } catch {
                DispatchQueue.main.async {
                    self.pathHistory = ["/"]
                    self.loadDir("/")
                }
            }
        }
    }

    private func loadDir(_ dirPath: String) {
        path = dirPath
        loading = true
        selectedEntry = nil
        let serverId = tab.serverId
        let bridge = appState.bridge
        blockingAsync {
            do {
                let result = try bridge.sftpListFast(serverId: serverId, path: dirPath)
                DispatchQueue.main.async {
                    self.entries = result
                    self.loading = false
                }
            } catch {
                print("加载目录失败: \(error)")
                DispatchQueue.main.async {
                    self.loading = false
                }
                return
            }
            do {
                let stats = try bridge.sftpStatDirEntries(serverId: serverId, path: dirPath)
                DispatchQueue.main.async {
                    guard self.path == dirPath else { return }
                    var statMap = [String: FileEntryStat]()
                    for s in stats { statMap[s.path] = s }
                    for i in self.entries.indices {
                        if let s = statMap[self.entries[i].path] {
                            self.entries[i].size = s.size
                            self.entries[i].modified = s.modified
                            self.entries[i].permissions = s.permissions
                        }
                    }
                }
            } catch {
                print("获取文件详情失败: \(error)")
            }
        }
    }

    private func navigateTo(_ newPath: String) {
        pathHistory.append(newPath)
        loadDir(newPath)
    }

    private func goBack() {
        guard pathHistory.count > 1 else { return }
        pathHistory.removeLast()
        loadDir(pathHistory.last!)
    }

    private func handleDownload() {
        guard let entry = selectedEntry, !entry.is_dir else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.beginSheetModal(for: NSApp.keyWindow!) { resp in
            guard resp == .OK, let url = panel.url else { return }
            transfer = TransferInfo(direction: "download", fileName: entry.name, transferred: 0, total: entry.size)
            let serverId = tab.serverId
            let remotePath = entry.path
            let localPath = url.path
            let bridge = appState.bridge
            OrbitBridge.shared.progressHandlers[serverId] = { (transferred: UInt64, total: UInt64) in
                DispatchQueue.main.async {
                    self.transfer?.transferred = transferred
                    self.transfer?.total = total
                    if transferred >= total { self.transfer = nil }
                }
            }
            blockingAsync {
                do {
                    try bridge.sftpDownload(serverId: serverId, remotePath: remotePath, localPath: localPath)
                    DispatchQueue.main.async {
                        self.transfer = nil
                        OrbitBridge.shared.progressHandlers.removeValue(forKey: serverId)
                    }
                } catch {
                    print("下载失败: \(error)")
                    DispatchQueue.main.async {
                        self.transfer = nil
                        OrbitBridge.shared.progressHandlers.removeValue(forKey: serverId)
                    }
                }
            }
        }
    }

    private func handleUpload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: NSApp.keyWindow!) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let fileName = url.lastPathComponent
            let remotePath = path == "/" ? "/\(fileName)" : "\(path)/\(fileName)"
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            transfer = TransferInfo(direction: "upload", fileName: fileName, transferred: 0, total: fileSize)
            let serverId = tab.serverId
            let localPath = url.path
            let bridge = appState.bridge
            let currentPath = path
            OrbitBridge.shared.progressHandlers[serverId] = { (transferred: UInt64, total: UInt64) in
                DispatchQueue.main.async {
                    self.transfer?.transferred = transferred
                    self.transfer?.total = total
                    if transferred >= total { self.transfer = nil }
                }
            }
            blockingAsync {
                do {
                    try bridge.sftpUpload(serverId: serverId, localPath: localPath, remotePath: remotePath)
                    DispatchQueue.main.async {
                        self.transfer = nil
                        OrbitBridge.shared.progressHandlers.removeValue(forKey: serverId)
                        self.loadDir(currentPath)
                    }
                } catch {
                    print("上传失败: \(error)")
                    DispatchQueue.main.async {
                        self.transfer = nil
                        OrbitBridge.shared.progressHandlers.removeValue(forKey: serverId)
                    }
                }
            }
        }
    }

    private func handleDelete() {
        guard let entry = selectedEntry else { return }
        let alert = NSAlert()
        alert.messageText = "确定删除 \"\(entry.name)\"？"
        alert.informativeText = "此操作不可撤销"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard let window = NSApp.keyWindow else { return }
        alert.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let serverId = self.tab.serverId
            let entryPath = entry.path
            let isDir = entry.is_dir
            let bridge = self.appState.bridge
            let currentPath = self.path
            self.blockingAsync {
                do {
                    try bridge.sftpRemove(serverId: serverId, path: entryPath, isDir: isDir)
                    DispatchQueue.main.async {
                        self.loadDir(currentPath)
                    }
                } catch {
                    print("删除失败: \(error)")
                }
            }
        }
    }

    private func blockingAsync(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }
}
