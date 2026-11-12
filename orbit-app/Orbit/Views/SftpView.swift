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
    let compact: Bool
    @ObservedObject private var queue: SftpTransferQueue
    @State private var search = ""
    @State private var showHidden = true
    @State private var pathInput = ""
    @State private var overwriteItem: SftpTransferQueue.Item?
    @State private var showMkdirAlert = false
    @State private var mkdirName = ""
    @State private var showRenameAlert = false
    @State private var renameName = ""
    @State private var errorTitle = ""
    @State private var errorMessage: String?
    @State private var dropHighlighted = false

    init(tab: TabItem, appState: AppState, compact: Bool = false) {
        self.tab = tab
        self.appState = appState
        self.compact = compact
        self.queue = appState.sftpQueue(for: tab)
    }

    private var filteredEntries: [FileEntry] {
        entries.filter { (showHidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            navigationBar
            fileTable
            if !queue.items.isEmpty { progressSection }
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if path.isEmpty { loadHome() } }
        .onChange(of: queue.revision) { _ in if !path.isEmpty { loadDir(path) } }
        .alert("替换已有文件？", isPresented: Binding(get: { overwriteItem != nil }, set: { if !$0 { overwriteItem = nil } })) {
            Button("取消", role: .cancel) { overwriteItem = nil }
            Button("替换", role: .destructive) {
                if let item = overwriteItem { queue.retry(item.id, overwrite: true) }
                overwriteItem = nil
            }
        } message: {
            Text("目标：\(overwriteItem?.destination ?? "")\n文件传输完成后才会替换原文件。")
        }
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("文件").font(.system(size: compact ? 14 : 20, weight: .semibold))
                if !compact {
                    Text("\(tab.serverName) · SFTP").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Toggle("显示隐藏文件", isOn: $showHidden)
                Button("新建文件夹") { showMkdirAlert = true }
                Button("下载选中文件", action: handleDownload).disabled(selectedEntry == nil || selectedEntry?.is_dir == true)
                Button("删除选中项", role: .destructive, action: handleDelete).disabled(selectedEntry == nil)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 24)
                .help("文件操作")
            Button(action: handleUpload) { Label("上传文件", systemImage: "arrow.up.doc") }
                .buttonStyle(.borderedProminent)
                .disabled(path.isEmpty)
                .accessibilityIdentifier("sftpUploadButton")
        }
        .padding(compact ? 10 : 18)
    }

    private var navigationBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: goBack) { Image(systemName: "chevron.left") }.disabled(pathHistory.count < 2).help("返回")
                Button { navigateTo((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }.help("上级目录")
                Button(action: loadHome) { Image(systemName: "house") }.help("主目录")
                TextField("远程路径", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { if !pathInput.isEmpty { navigateTo(pathInput) } }
                    .accessibilityIdentifier("sftpPathField")
                Button { loadDir(path) } label: { Image(systemName: "arrow.clockwise") }.disabled(path.isEmpty || loading).help("刷新目录")
            }
            .buttonStyle(.plain)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选文件", text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }
            .font(.system(size: 12))
            .padding(7)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, compact ? 10 : 18)
        .padding(.bottom, 12)
    }

    private var fileTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("大小").frame(width: compact ? 65 : 80, alignment: .trailing)
                if !compact {
                    Text("修改时间").frame(width: 140, alignment: .trailing)
                    Text("权限").frame(width: 64, alignment: .trailing)
                }
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 10 : 18).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEntries) { entry in row(for: entry) }
                    }
                }
                if loading {
                    ProgressView().padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                } else if filteredEntries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: search.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text(search.isEmpty ? "此文件夹为空" : "没有匹配的文件").font(.system(size: 13, weight: .medium))
                        Text(search.isEmpty ? "拖入文件，或点击上传文件" : "试试其他名称").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }
            .background(dropHighlighted ? Color.accentColor.opacity(0.08) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(dropHighlighted ? Color.accentColor : .clear, lineWidth: 2))
            .onDrop(of: [.fileURL], isTargeted: $dropHighlighted, perform: handleDrop)
        }
    }

    private func row(for entry: FileEntry) -> some View {
        let isSelected = selectedEntry?.path == entry.path
        return HStack(spacing: 8) {
            Image(systemName: entryIcon(entry))
                .foregroundStyle(entry.is_dir ? Color.accentColor : Color.secondary)
                .font(.system(size: 13))
                .frame(width: 20)

            Text(entry.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.is_dir ? "-" : formatSize(entry.size))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 65 : 80, alignment: .trailing)

            if !compact {
                Text(entry.modified).foregroundStyle(.secondary).frame(width: 140, alignment: .trailing)
                Text(entry.permissions).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, compact ? 10 : 18)
        .padding(.vertical, compact ? 7 : 9)
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
                    guard let serverId = tab.serverId else { return }
                    print("[SftpView] contextMenu 编辑: \(entry.path) isTextFile=true")
                    selectedEntry = entry
                    appState.textEditorWC.open(serverId: serverId, filePath: entry.path, fileName: entry.name)
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
            HStack {
                Label("传输队列", systemImage: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold))
                Text("\(queue.items.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("清除已结束", action: queue.clearFinished).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, compact ? 10 : 18).padding(.vertical, 10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue.items) { item in transferRow(item) }
                }
            }
            .frame(height: compact ? min(90, CGFloat(queue.items.count) * 64) : min(190, CGFloat(queue.items.count) * 80))
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private func transferRow(_ item: SftpTransferQueue.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.system(size: 17)).foregroundStyle(Color.accentColor).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(item.status.label).font(.system(size: 10)).foregroundStyle(item.status == .completed ? Color.green : Color.secondary).lineLimit(1).help(item.status.label)
                }
                Text(item.destination).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                if item.status == .running || item.status == .cancelling {
                    ProgressView(value: min(Double(item.transferred), Double(max(item.total, 1))), total: Double(max(item.total, 1)))
                        .progressViewStyle(.linear)
                    Text("\(formatSize(item.transferred)) / \(formatSize(item.total))").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Group {
                switch item.status {
                case .conflict:
                    Button("替换…") { overwriteItem = item }
                    Button { queue.cancel(item.id) } label: { Image(systemName: "xmark") }.help("跳过此文件")
                case .failed, .cancelled:
                    Button("重试") { queue.retry(item.id) }
                case .queued, .running:
                    Button { queue.cancel(item.id) } label: { Image(systemName: "xmark.circle") }.help("取消传输")
                case .cancelling:
                    ProgressView().controlSize(.small)
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .buttonStyle(.borderless).font(.system(size: 11))
        }
        .padding(.horizontal, compact ? 10 : 18).padding(.vertical, 9)
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
        guard !path.isEmpty else { return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
            errorTitle = "无法上传"
            errorMessage = "请选择普通文件；暂不支持文件夹传输。"
            return
        }
        let remote = path == "/" ? "/\(url.lastPathComponent)" : "\(path)/\(url.lastPathComponent)"
        queue.enqueue(local: url.path, remote: remote, upload: true)
    }

    private var statusBar: some View {
        HStack {
            Text("\(filteredEntries.count) 项")
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
        guard let serverId = tab.serverId else { return }
        blockingAsync {
            do {
                let home = try self.appState.bridge.getServerHome(serverId: serverId)
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
        guard let serverId = tab.serverId else { return }
        print("[SftpView] loadDir: \(dirPath)")
        path = dirPath
        pathInput = dirPath
        loading = true
        selectedEntry = nil
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
                    guard self.path == dirPath else { return }
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
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            queue.enqueue(local: url.path, remote: entry.path, upload: false)
        }
    }

    private func handleUpload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            panel.urls.forEach(queueUpload)
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
            guard let serverId = self.tab.serverId else { return }
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
        guard let serverId = tab.serverId else { return }
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
        guard let serverId = tab.serverId else { return }
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
