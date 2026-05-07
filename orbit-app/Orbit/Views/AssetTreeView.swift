import SwiftUI

struct AssetTreeView: View {
    @EnvironmentObject var appState: AppState

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
                LazyVStack(spacing: 0, pinnedViews: []) {
                    if appState.assetTreeSearchQuery.isEmpty {
                        serverGroupsSection
                        credentialsSection
                        snippetsSection
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
    }

    // MARK: - Server Groups

    private var serverGroupsSection: some View {
        let groups = Dictionary(grouping: appState.servers) {
            $0.group_name.isEmpty ? "服务器" : $0.group_name
        }
        let sorted = groups.sorted { $0.key < $1.key }

        return ForEach(sorted, id: \.key) { groupName, servers in
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedGroups.contains(groupName) },
                    set: { isExpanded in
                        if isExpanded { expandedGroups.insert(groupName) }
                        else { expandedGroups.remove(groupName) }
                    }
                ),
                content: {
                    ForEach(servers) { server in
                        ServerNodeRow(server: server)
                    }
                },
                label: {
                    HStack {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                        Text(groupName)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(servers.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            )
        }
        .padding(.vertical, 2)
    }

    @State private var expandedGroups: Set<String> = []

    // MARK: - Credentials Section

    private var credentialsSection: some View {
        let filtered = appState.credentialGroups
        guard !filtered.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            DisclosureGroup(
                isExpanded: $credentialsExpanded,
                content: {
                    ForEach(filtered) { cg in
                        HStack {
                            Image(systemName: "key")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow)
                            Text(cg.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            appState.openCgDialog(cg)
                        }
                    }
                },
                label: {
                    HStack {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 11))
                            .foregroundStyle(.gray)
                        Text("凭据组")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            )
        )
    }

    @State private var credentialsExpanded: Bool = false

    // MARK: - Snippets Section

    private var snippetsSection: some View {
        let filtered = appState.snippets
        guard !filtered.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            DisclosureGroup(
                isExpanded: $snippetsExpanded,
                content: {
                    ForEach(filtered) { snippet in
                        HStack {
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
                        .padding(.horizontal, 12)
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
                    }
                },
                label: {
                    HStack {
                        Image(systemName: "text.insert")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        Text("命令片段")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(filtered.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            )
        )
    }

    @State private var snippetsExpanded: Bool = false

    // MARK: - Search Results

    private var searchResults: some View {
        let q = appState.assetTreeSearchQuery.lowercased()
        let matched = appState.servers.filter {
            $0.name.lowercased().contains(q) || $0.host.lowercased().contains(q)
        }
        return ForEach(matched) { server in
            ServerNodeRow(server: server)
        }
    }
}

// MARK: - Server Node Row

private struct ServerNodeRow: View {
    let server: Server
    @EnvironmentObject var appState: AppState

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
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
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
