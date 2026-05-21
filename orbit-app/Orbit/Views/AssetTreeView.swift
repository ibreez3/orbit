import SwiftUI

struct AssetTreeView: View {
    @EnvironmentObject var appState: AppState

    @State private var serversExpanded: Bool = true
    @State private var credentialsExpanded: Bool = false
    @State private var snippetsExpanded: Bool = false
    @State private var expandedSubGroups: Set<String> = []
    @State private var renameTarget: String? = nil
    @State private var renameText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("搜索服务器...", text: $appState.assetTreeSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !appState.assetTreeSearchQuery.isEmpty {
                    Button(action: { appState.assetTreeSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Tree content
            ScrollView {
                VStack(spacing: 0) {
                    if appState.assetTreeSearchQuery.isEmpty {
                        categoryServers
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
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 160)
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $appState.snippetEditorOpen) {
            SnippetEditorView()
                .environmentObject(appState)
        }
        .alert("重命名分组", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("分组名", text: $renameText)
            Button("确定") {
                if let oldName = renameTarget, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    appState.updateServerGroupName(oldName: oldName, newName: renameText.trimmingCharacters(in: .whitespaces))
                }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        } message: {
            Text("修改后，该分组下的所有服务器将更新分组名")
        }
    }

    // MARK: - Category: Servers

    private var categoryServers: some View {
        VStack(spacing: 0) {
            // Category header — click to expand
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { serversExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(serversExpanded ? 90 : 0))
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                    Text("服务器")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(appState.servers.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if serversExpanded {
                let groups = Dictionary(grouping: appState.servers) {
                    $0.group_name.isEmpty ? "默认" : $0.group_name
                }
                let sorted = groups.sorted { $0.key < $1.key }

                ForEach(sorted, id: \.key) { groupName, servers in
                    serverSubGroup(groupName: groupName, servers: servers)
                }
            }

            Divider()
                .padding(.leading, 12)
        }
    }

    private func serverSubGroup(groupName: String, servers: [Server]) -> some View {
        let isExpanded = expandedSubGroups.contains(groupName)

        return VStack(spacing: 0) {
            // Sub-group header — click to expand
            Button(action: {
                if isExpanded { expandedSubGroups.remove(groupName) }
                else { expandedSubGroups.insert(groupName) }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text(groupName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(servers.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 28)
                .padding(.trailing, 12)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("重命名") {
                    renameTarget = groupName
                    renameText = groupName
                }
            }

            if isExpanded {
                ForEach(servers) { server in
                    ServerNodeRow(server: server, indent: 40)
                }
            }
        }
    }

    // MARK: - Category: Credentials

    private var categoryCredentials: some View {
        let items = appState.credentialGroups

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
        let items = appState.snippets

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
                        if let activeId = appState.activeTabId,
                           let tab = appState.tabs.first(where: { $0.id == activeId }),
                           let sid = tab.sessionId ?? tab.focusedChannelId,
                           let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView {
                            appState.insertSnippetCommand(snippet.command, into: tv)
                        } else {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(snippet.command, forType: .string)
                        }
                    }
                    .contextMenu {
                        Button("插入到终端") {
                            if let activeId = appState.activeTabId,
                               let tab = appState.tabs.first(where: { $0.id == activeId }),
                               let sid = tab.sessionId ?? tab.focusedChannelId,
                               let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView {
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
        let q = appState.assetTreeSearchQuery.lowercased()
        let matched = appState.servers.filter {
            $0.name.lowercased().contains(q) || $0.host.lowercased().contains(q)
        }
        return ForEach(matched) { server in
            ServerNodeRow(server: server, indent: 12)
        }
    }
}

// MARK: - Server Node Row

private struct ServerNodeRow: View {
    let server: Server
    var indent: CGFloat = 12
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.tabs.contains(where: { $0.serverId == server.id }) ? Color.green : Color.gray)
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
            appState.trackRecentServer(server.id)
        }
        .contextMenu {
            Button("SSH 终端") { appState.addTab(server: server, type: .terminal) }
            Button("SFTP") { appState.addTab(server: server, type: .sftp) }
            Button("监控") { appState.addTab(server: server, type: .monitor) }
            Divider()
            Button("编辑") { appState.openDialog(server: server) }
            Button("删除", role: .destructive) { appState.deleteServer(server.id) }
        }
    }
}
