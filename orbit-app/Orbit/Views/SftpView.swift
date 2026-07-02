import SwiftUI
import UniformTypeIdentifiers

struct SftpView: View {
    let tab: TabItem
    let appState: AppState
    @State private var path: String = ""
    @State private var entries: [FileEntry] = []
    @State private var loading: Bool = false
    @State private var selectedEntry: FileEntry?
    @State private var lastClickTime: Date = .distantPast
    @State private var lastClickPath: String = ""
    @State private var pathHistory: [String] = []
    @State private var transfer: TransferInfo?
    @State private var transferTasks: [TransferTask] = []
    @State private var showMkdirAlert = false
    @State private var mkdirName = ""
    @State private var showRenameAlert = false
    @State private var renameName = ""
    @State private var errorTitle = ""
    @State private var errorMessage: String?
    @State private var dropHighlighted = false

    struct TransferInfo {
        let direction: String
        let fileName: String
        var transferred: UInt64
        var total: UInt64
    }

    struct TransferTask: Identifiable {
        let id = UUID()
        let direction: String
        let fileName: String
        let localPath: String?
        let remotePath: String
        var transferred: UInt64
        var total: UInt64
        var status: TransferStatus = .queued
    }

    enum TransferStatus: Equatable {
        case queued
        case transferring
        case completed
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            fileTable
            if transfer != nil || !transferTasks.isEmpty {
                progressSection
            }
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadHome() }
        .onDisappear { appState.setSftpTransferActive(false, for: tab.id) }
        .alert("重命名", isPresented: $showRenameAlert) {
            TextField("新名称", text: $renameName)
            Button("确定") { handleRename() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入新文件名")
        }
        .alert("新建文件夹", isPresented: $showMkdirAlert) {
            TextField("文件夹名称", text: $mkdirName)
            Button("确定") { handleMkdir() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入文件夹名称")
        }
        .alert(errorTitle, isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: goBack) {
                Image(systemName: "arrow.left")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("返回")
            .accessibilityLabel("返回上级目录")

            Button(action: { loadDir(path) }) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("刷新")
            .accessibilityLabel("刷新目录")

            Button(action: { navigateTo("/") }) {
                Image(systemName: "house")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("根目录")
            .accessibilityLabel("根目录")

            pathBreadcrumb

            Spacer()

            Button(action: handleDownload) {
                Image(systemName: "arrow.down.to.line")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(selectedEntry == nil || selectedEntry!.is_dir || transfer != nil)
            .help("下载")
            .accessibilityLabel("下载选中文件")

            Button(action: handleUpload) {
                Image(systemName: "arrow.up.to.line")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(transfer != nil)
            .help("上传")
            .accessibilityLabel("上传文件")

            Button(action: { showMkdirAlert = true }) {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("新建文件夹")
            .accessibilityLabel("新建文件夹")

            Button(action: handleDelete) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selectedEntry != nil ? .red : .secondary)
            .disabled(selectedEntry == nil)
            .help("删除")
            .accessibilityLabel("删除选中项")
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
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(dropHighlighted ? Color.accentColor : Color.clear, lineWidth: 2)
                        .padding(2)
                )
                .background(dropHighlighted ? Color.accentColor.opacity(0.05) : Color.clear)
                .onDrop(of: [.fileURL], isTargeted: $dropHighlighted) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
    }

    private func row(for entry: FileEntry) -> some View {
        let isSelected = selectedEntry?.path == entry.path
        return HStack(spacing: 8) {
            Button { selectOrNavigate(entry: entry) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)

            Image(systemName: entryIcon(entry))
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
        .onTapGesture { selectOrNavigate(entry: entry) }
        .contextMenu { contextMenuItems(for: entry) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(entry.is_dir ? "文件夹" : formatSize(entry.size))")
        .accessibilityAddTraits(entry.is_dir ? [] : .isButton)
    }

    private func entryIcon(_ entry: FileEntry) -> String {
        if entry.is_dir { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let textExts: Set<String> = ["txt", "md", "json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "log", "csv", "html", "htm", "css", "js", "ts", "py", "rb", "go", "rs", "java", "c", "cpp", "h", "hpp", "sh", "bash", "zsh", "fish", "sql", "env", "gitignore", "dockerignore", "makefile", "cmake", "gradle", "properties", "plist", "lock", "sum"]
        return textExts.contains(ext) || entry.name.lowercased() == "makefile" || entry.name.lowercased() == "dockerfile" ? "doc.text" : "doc"
    }

    private func isTextFile(_ entry: FileEntry) -> Bool {
        guard !entry.is_dir else { return false }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let textExts: Set<String> = [
            "txt", "md", "json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf",
            "log", "csv", "tsv", "html", "htm", "css", "scss", "less", "js", "jsx",
            "ts", "tsx", "py", "rb", "go", "rs", "java", "c", "cpp", "cc", "h", "hpp",
            "sh", "bash", "zsh", "fish", "sql", "env", "gitignore", "gitattributes",
            "gitmodules", "dockerignore", "cmake", "gradle", "properties", "plist",
            "lock", "sum", "rss", "atom", "svg", "tex", "bib", "rst", "org",
            "bashrc", "zshrc", "zprofile", "zshenv", "profile", "vimrc", "gvimrc",
            "gitconfig", "hgrc", "npmrc", "gemrc", "cargo", "editorconfig",
            "babelrc", "eslintrc", "prettierrc", "stylelintrc", "ember-cli",
        ]
        if textExts.contains(ext) { return true }
        let nameLower = entry.name.lowercased()
        let knownTextNames: Set<String> = [
            "makefile", "dockerfile", "vagrantfile", "gemfile", "rakefile",
            "cmakelists.txt", "changelog", "contributing", "authors", "patents",
            "license", "copying", "notice", "readme",
        ]
        if knownTextNames.contains(nameLower) { return true }
        if nameLower.hasPrefix("readme") { return true }
        let startsWithDot = entry.name.hasPrefix(".")
        return startsWithDot && textExts.contains(ext)
    }

    @ViewBuilder
    private func contextMenuItems(for entry: FileEntry) -> some View {
        if !entry.is_dir {
            Button("下载") {
                print("[SftpView] contextMenu 下载: \(entry.path)")
                selectedEntry = entry
                downloadFile(entry)
            }
            Button("重命名") {
                print("[SftpView] contextMenu 重命名: \(entry.path)")
                selectedEntry = entry
                renameName = entry.name
                showRenameAlert = true
            }
            Divider()
            if isTextFile(entry) {
                Button("编辑") {
                    print("[SftpView] contextMenu 编辑: \(entry.path) isTextFile=true")
                    selectedEntry = entry
                    appState.textEditorWC.open(serverId: tab.serverId, filePath: entry.path, fileName: entry.name)
                }
            }
            Divider()
        }
        Button("删除") {
            print("[SftpView] contextMenu 删除: \(entry.path)")
            selectedEntry = entry
            handleDelete()
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

    private var progressSection: some View {
        VStack(spacing: 0) {
            Divider()
            if let t = transfer {
                progressRow(direction: t.direction, fileName: t.fileName, transferred: t.transferred, total: t.total, status: nil)
            }
            ForEach(transferTasks) { task in
                progressRow(
                    direction: task.direction,
                    fileName: task.fileName,
                    transferred: task.transferred,
                    total: task.total,
                    status: task.status
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func progressRow(direction: String, fileName: String, transferred: UInt64, total: UInt64, status: SftpView.TransferStatus?) -> some View {
        let pct = total > 0 ? Int(Double(transferred) / Double(total) * 100) : 0
        return HStack(spacing: 8) {
            Image(systemName: direction == "download" ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(direction == "download" ? .blue : .green)

            Text(fileName)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            if let status = status, case .failed(let msg) = status {
                Text("失败: \(msg)")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if let status = status, case .completed = status {
                Text("完成")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            } else if let status = status, case .queued = status {
                Text("排队中")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: Double(pct), total: 100)
                    .frame(width: 100)
                Text("\(formatSize(transferred))\(total > 0 ? " / \(formatSize(total))" : "")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if status != nil {
                Button(action: {
                    transferTasks.removeAll { $0.id == transferTasks.first(where: { t in
                        t.fileName == fileName && t.remotePath == transferTasks.first?.remotePath
                    })?.id }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 22)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    queueUpload(url: url)
                }
            }
        }
        return true
    }

    private func queueUpload(url: URL) {
        let fileName = url.lastPathComponent
        let remotePath = path == "/" ? "/\(fileName)" : "\(path)/\(fileName)"
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let task = TransferTask(
            direction: "upload",
            fileName: fileName,
            localPath: url.path,
            remotePath: remotePath,
            transferred: 0,
            total: fileSize,
            status: .queued
        )
        transferTasks.append(task)
        processNextUpload()
    }

    private func processNextUpload() {
        guard let idx = transferTasks.firstIndex(where: { $0.status == .queued }) else {
            if transferTasks.allSatisfy({ $0.status != .transferring }) {
                appState.setSftpTransferActive(false, for: tab.id)
            }
            return
        }
        transferTasks[idx].status = .transferring
        let task = transferTasks[idx]
        let taskId = task.id
        let serverId = tab.serverId
        let localPath = task.localPath ?? ""
        let remotePath = task.remotePath
        let currentPath = path
        let bridge = appState.bridge

        appState.setSftpTransferActive(true, for: tab.id)

        blockingAsync {
            do {
                try bridge.sftpUploadWithProgress(
                    serverId: serverId,
                    localPath: localPath,
                    remotePath: remotePath,
                    progress: { transferred, total in
                        DispatchQueue.main.async {
                            if let i = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                                self.transferTasks[i].transferred = transferred
                                self.transferTasks[i].total = total
                            }
                        }
                    }
                )
                DispatchQueue.main.async {
                    if let i = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[i].status = .completed
                    }
                    self.loadDir(currentPath)
                    self.processNextUpload()
                }
            } catch {
                DispatchQueue.main.async {
                    if let i = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[i].status = .failed(error.localizedDescription)
                    }
                    self.processNextUpload()
                }
            }
        }
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
        print("[SftpView] loadDir: \(dirPath)")
        path = dirPath
        loading = true
        selectedEntry = nil
        let serverId = tab.serverId
        let bridge = appState.bridge
        blockingAsync {
            do {
                let result = try bridge.sftpListFull(serverId: serverId, path: dirPath)
                DispatchQueue.main.async {
                    guard self.path == dirPath else { return }
                    self.entries = result
                    self.loading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorTitle = "加载目录失败"
                    self.errorMessage = error.localizedDescription
                    self.loading = false
                }
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
        downloadFile(entry)
    }

    private func downloadFile(_ entry: FileEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.beginSheetModal(for: NSApp.keyWindow!) { resp in
            guard resp == .OK, let url = panel.url else { return }
            transfer = TransferInfo(direction: "download", fileName: entry.name, transferred: 0, total: entry.size)
            let serverId = tab.serverId
            let remotePath = entry.path
            let localPath = url.path
            let bridge = appState.bridge
            appState.setSftpTransferActive(true, for: tab.id)
            OrbitBridge.shared.handlersLock.lock()
            OrbitBridge.shared.progressHandlers[serverId] = { (transferred: UInt64, total: UInt64) in
                DispatchQueue.main.async {
                    self.transfer?.transferred = transferred
                    self.transfer?.total = total
                    if transferred >= total {
                        self.transfer = nil
                        self.appState.setSftpTransferActive(false, for: self.tab.id)
                    }
                }
            }
            OrbitBridge.shared.handlersLock.unlock()
            blockingAsync {
                do {
                    try bridge.sftpDownload(serverId: serverId, remotePath: remotePath, localPath: localPath)
                    DispatchQueue.main.async {
                        self.transfer = nil
                        self.appState.setSftpTransferActive(false, for: self.tab.id)
                        OrbitBridge.shared.handlersLock.lock()
                        OrbitBridge.shared.progressHandlers.removeValue(forKey: serverId)
                        OrbitBridge.shared.handlersLock.unlock()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.errorTitle = "下载失败"
                        self.errorMessage = error.localizedDescription
                        self.transfer = nil
                        self.appState.setSftpTransferActive(false, for: self.tab.id)
                        OrbitBridge.shared.handlersLock.lock()
                        OrbitBridge.shared.progressHandlers.removeValue(forKey: serverId)
                        OrbitBridge.shared.handlersLock.unlock()
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
            appState.setSftpTransferActive(true, for: tab.id)
            OrbitBridge.shared.handlersLock.lock()
            OrbitBridge.shared.progressHandlers[serverId] = { (transferred: UInt64, total: UInt64) in
                DispatchQueue.main.async {
                    self.transfer?.transferred = transferred
                    self.transfer?.total = total
                    if transferred >= total {
                        self.transfer = nil
                        self.appState.setSftpTransferActive(false, for: self.tab.id)
                    }
                }
            }
            OrbitBridge.shared.handlersLock.unlock()
            blockingAsync {
                do {
                    try bridge.sftpUpload(serverId: serverId, localPath: localPath, remotePath: remotePath)
                    DispatchQueue.main.async {
                        self.transfer = nil
                        self.appState.setSftpTransferActive(false, for: self.tab.id)
                        OrbitBridge.shared.handlersLock.lock()
                        OrbitBridge.shared.progressHandlers.removeValue(forKey: serverId)
                        OrbitBridge.shared.handlersLock.unlock()
                        self.loadDir(currentPath)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.errorTitle = "上传失败"
                        self.errorMessage = error.localizedDescription
                        self.transfer = nil
                        self.appState.setSftpTransferActive(false, for: self.tab.id)
                        OrbitBridge.shared.handlersLock.lock()
                        OrbitBridge.shared.progressHandlers.removeValue(forKey: serverId)
                        OrbitBridge.shared.handlersLock.unlock()
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
                    DispatchQueue.main.async {
                        self.errorTitle = "删除失败"
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func handleRename() {
        guard let entry = selectedEntry, !renameName.isEmpty, renameName != entry.name else { return }
        let serverId = tab.serverId
        let oldPath = entry.path
        let newPath = path == "/" ? "/\(renameName)" : "\(path)/\(renameName)"
        let bridge = appState.bridge
        let currentPath = path
        blockingAsync {
            do {
                try bridge.sftpRename(serverId: serverId, oldPath: oldPath, newPath: newPath)
                DispatchQueue.main.async {
                    self.loadDir(currentPath)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorTitle = "重命名失败"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleMkdir() {
        guard !mkdirName.isEmpty else { return }
        let serverId = tab.serverId
        let dirPath = path == "/" ? "/\(mkdirName)" : "\(path)/\(mkdirName)"
        let bridge = appState.bridge
        let currentPath = path
        blockingAsync {
            do {
                try bridge.sftpMkdir(serverId: serverId, path: dirPath)
                DispatchQueue.main.async {
                    self.loadDir(currentPath)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorTitle = "新建文件夹失败"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func blockingAsync(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }
}
