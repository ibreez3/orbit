import SwiftUI

struct AssetTreeView: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject var uiState: UIState
    @EnvironmentObject var inventoryState: InventoryState
    @EnvironmentObject var snippetState: SnippetState
    @EnvironmentObject var tabState: TabState

    @State private var databasesExpanded: Bool = true
    @State private var credentialsExpanded: Bool = false
    @State private var snippetsExpanded: Bool = false
    @State private var expandedDatabaseGroups: Set<String> = []

    var body: some View {
        Group {
            if uiState.assetTreeCollapsed {
                collapsedTree
            } else {
                expandedTree
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $snippetState.snippetEditorOpen) {
            SnippetEditorView(appState: appState)
                .environmentObject(appState.snippetState)
        }
    }

    private var expandedTree: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("搜索资产...", text: $uiState.assetTreeSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityLabel("搜索资产")
                if !uiState.assetTreeSearchQuery.isEmpty {
                    Button(action: { uiState.assetTreeSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Tree content
            ScrollView {
                VStack(spacing: 0) {
                    if uiState.assetTreeSearchQuery.isEmpty {
                        categoryServers
                        categoryDatabases
                        categoryCredentials
                        categorySnippets
                    } else {
                        searchResults
                    }
                }
                .padding(.bottom, 28)
            }

            Divider()

            // Bottom toolbar
            HStack {
                Button(action: { appState.openDialog() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("添加服务器")
                            .font(.system(size: 11))
                    }
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("添加服务器")
                Spacer()
                Button {
                    uiState.assetTreeCollapsed = true
                    appState.saveAssetTreePresentation()
                } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("折叠资产栏")
                .accessibilityLabel("折叠资产栏")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 180)
    }

    private var collapsedTree: some View {
        VStack(spacing: 8) {
            Button {
                uiState.assetTreeCollapsed = false
                appState.saveAssetTreePresentation()
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("展开资产栏")
            .accessibilityLabel("展开资产栏")

            Divider().padding(.horizontal, 8)

            collapsedButton(icon: "desktopcomputer", label: "服务器") {
                uiState.assetTreeCollapsed = false
                appState.selectServerSystemView(.all)
                appState.saveAssetTreePresentation()
            }
            collapsedButton(icon: "cylinder.split.1x2", label: "数据库") {
                uiState.assetTreeCollapsed = false
                appState.saveAssetTreePresentation()
            }
            collapsedButton(icon: "lock.shield", label: "凭据组") {
                uiState.assetTreeCollapsed = false
                appState.saveAssetTreePresentation()
            }
            collapsedButton(icon: "text.insert", label: "命令片段") {
                uiState.assetTreeCollapsed = false
                appState.saveAssetTreePresentation()
            }

            Spacer()

            Button { appState.openDialog() } label: {
                Image(systemName: "plus")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("添加服务器")
            .accessibilityLabel("添加服务器")
        }
        .padding(.vertical, 8)
        .frame(width: 48)
    }

    private func collapsedButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Category: Servers

    private var categoryServers: some View {
        ServerTreeSection(appState: appState)
    }

    // MARK: - Category: Databases

    private var categoryDatabases: some View {
        let items = inventoryState.databaseConnections

        return AnyView(VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { databasesExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(databasesExpanded ? 90 : 0))
                    Image(systemName: "cylinder.split.1x2")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple)
                    Text("数据库")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(action: { appState.openDatabaseConnectionDialog() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("新建数据库连接")
                    Text("\(items.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if databasesExpanded {
                if items.isEmpty {
                    Text("暂无数据库连接，点击 + 创建")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 28)
                        .padding(.vertical, 8)
                }

                let groups = Dictionary(grouping: items) {
                    $0.group_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "默认" : $0.group_name
                }
                let sorted = groups.sorted { $0.key < $1.key }

                ForEach(sorted, id: \.key) { groupName, connections in
                    databaseSubGroup(groupName: groupName, connections: connections.sorted { $0.name < $1.name })
                }
            }

            Divider()
                .padding(.leading, 12)
        })
    }

    private func databaseSubGroup(groupName: String, connections: [DatabaseConnection]) -> some View {
        let isExpanded = expandedDatabaseGroups.contains(groupName)

        return VStack(spacing: 0) {
            Button(action: {
                if isExpanded { expandedDatabaseGroups.remove(groupName) }
                else { expandedDatabaseGroups.insert(groupName) }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                    Text(groupName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(connections.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 28)
                .padding(.trailing, 12)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(connections) { connection in
                    DatabaseNodeRow(connection: connection, appState: appState, indent: 40)
                }
            }
        }
    }

    // MARK: - Category: Credentials

    private var categoryCredentials: some View {
        let items = inventoryState.credentialGroups

        return AnyView(VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { credentialsExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(credentialsExpanded ? 90 : 0))
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                    Text("凭据组")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(action: { appState.openCgDialog() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("新建凭据组")
                    Text("\(items.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if credentialsExpanded {
                if items.isEmpty {
                    Text("暂无凭据组")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 28)
                        .padding(.vertical, 8)
                }
                ForEach(items) { cg in
                    HStack(spacing: 8) {
                        Image(systemName: "key")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                        Text(cg.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, 28)
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        appState.openCgDialog(cg)
                    }
                    .contextMenu {
                        Button("编辑") { appState.openCgDialog(cg) }
                        Button("删除", role: .destructive) { appState.deleteCg(cg.id) }
                    }
                }
            }

            Divider()
                .padding(.leading, 12)
        })
    }

    // MARK: - Category: Snippets

    private var categorySnippets: some View {
        let items = snippetState.snippets

        return AnyView(VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { snippetsExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(snippetsExpanded ? 90 : 0))
                    Image(systemName: "text.insert")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("命令片段")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(action: { appState.openTool(.snippets) }) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("打开片段面板")
                    Button(action: { appState.openSnippetEditor() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("新建片段")
                    Text("\(items.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if snippetsExpanded {
                if items.isEmpty {
                    Text("暂无命令片段，点击 + 创建")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 28)
                        .padding(.vertical, 8)
                }
                ForEach(items) { snippet in
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text(snippet.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                        Text(snippet.command)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.leading, 28)
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let activeId = tabState.activeTabId,
                           let tab = tabState.tabs.first(where: { $0.id == activeId }),
                           let sid = tab.focusedChannelId ?? tab.sessionId,
                           let tv = OrbitBridge.shared.terminalView(for: sid) as? OrbitTerminalView {
                            appState.insertSnippetCommand(snippet.command, into: tv)
                        } else {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(snippet.command, forType: .string)
                        }
                    }
                    .contextMenu {
                        Button("插入到终端") {
                            if let activeId = tabState.activeTabId,
                               let tab = tabState.tabs.first(where: { $0.id == activeId }),
                               let sid = tab.focusedChannelId ?? tab.sessionId,
                               let tv = OrbitBridge.shared.terminalView(for: sid) as? OrbitTerminalView {
                                appState.insertSnippetCommand(snippet.command, into: tv)
                            } else {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(snippet.command, forType: .string)
                            }
                        }
                        Button("编辑") { appState.openSnippetEditor(snippet: snippet) }
                        Button("删除", role: .destructive) { appState.deleteSnippet(snippet.id) }
                    }
                }
            }

            Divider()
                .padding(.leading, 12)
        })
    }

    // MARK: - Search Results

    private var searchResults: some View {
        let q = uiState.assetTreeSearchQuery.lowercased()
        let matchedDatabases = inventoryState.databaseConnections.filter {
            $0.name.lowercased().contains(q)
                || $0.group_name.lowercased().contains(q)
                || $0.host.lowercased().contains(q)
                || $0.database_name.lowercased().contains(q)
                || $0.sqlite_path.lowercased().contains(q)
        }

        return VStack(spacing: 0) {
            ServerTreeSection(appState: appState, searchQuery: q, showsHeader: false)
            ForEach(matchedDatabases) { connection in
                DatabaseNodeRow(connection: connection, appState: appState, indent: 12)
            }
        }
    }
}

// MARK: - Server Node Row

struct ServerNodeRow: View {
    let server: Server
    let appState: AppState
    var indent: CGFloat = 12
    @EnvironmentObject var tabState: TabState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tabState.tabs.contains(where: { $0.serverId == server.id }) ? Color.green : Color.gray)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text("\(server.host):\(server.port)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.leading, indent)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            appState.addTab(server: server, type: .terminal)
        }
        .contextMenu {
            Button("SSH 终端") { appState.addTab(server: server, type: .terminal) }
            Button("SFTP") { appState.addTab(server: server, type: .sftp) }
            Button("监控") { appState.addTab(server: server, type: .monitor) }
            Button("Docker") { appState.addTab(server: server, type: .docker) }
            Divider()
            Button("编辑") { appState.openDialog(server: server) }
            Button(server.is_pinned ? "取消置顶" : "置顶") {
                appState.setServerPinned(server, isPinned: !server.is_pinned)
            }
            Menu("移动到") {
                Button("未分类") { appState.moveServer(server, toFolderId: nil) }
                ForEach(appState.serverOrganization.folders.sorted(by: folderOrder)) { folder in
                    Button(folderPath(folder)) { appState.moveServer(server, toFolderId: folder.id) }
                }
            }
            Divider()
            Button("删除", role: .destructive) { appState.deleteServer(server.id) }
        }
    }

    private func folderOrder(_ lhs: ServerFolder, _ rhs: ServerFolder) -> Bool {
        if lhs.sort_order != rhs.sort_order { return lhs.sort_order < rhs.sort_order }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func folderPath(_ folder: ServerFolder) -> String {
        ServerTreeProjection(
            snapshot: appState.serverOrganization,
            servers: []
        ).path(forFolderId: folder.id) ?? folder.name
    }
}

// MARK: - Database Node Row

private struct DatabaseNodeRow: View {
    let connection: DatabaseConnection
    let appState: AppState
    var indent: CGFloat = 12
    @EnvironmentObject var tabState: TabState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tabState.tabs.contains(where: { $0.type == .database && $0.serverId == connection.id }) ? Color.green : Color.gray)
                .frame(width: 6, height: 6)

            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundStyle(iconColor)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.leading, indent)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            appState.openDatabaseConnection(connection)
        }
        .contextMenu {
            Button("打开") { appState.openDatabaseConnection(connection) }
            Button("测试连接") { appState.testDatabaseConnection(connection) }
            Button("备份") { appState.backupDatabaseConnection(connection) }
            Divider()
            Button("编辑") { appState.openDatabaseConnectionDialog(connection) }
            Button("删除", role: .destructive) { appState.deleteDatabaseConnection(connection.id) }
        }
    }

    private var iconName: String {
        switch connection.engine {
        case "remote_sqlite": return "externaldrive.connected.to.line.below"
        case "postgres": return "cylinder"
        default: return "cylinder.split.1x2"
        }
    }

    private var iconColor: Color {
        switch connection.engine {
        case "remote_sqlite": return .blue
        case "postgres": return .indigo
        default: return .orange
        }
    }

    private var subtitle: String {
        if connection.engine == "remote_sqlite" {
            return connection.sqlite_path.isEmpty ? "Remote SQLite" : connection.sqlite_path
        }
        let endpoint = connection.host.isEmpty ? connection.engineLabel : "\(connection.host):\(connection.port)"
        if connection.database_name.isEmpty { return endpoint }
        return "\(endpoint)/\(connection.database_name)"
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
