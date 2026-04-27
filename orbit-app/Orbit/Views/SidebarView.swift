import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) var appState
    @State private var expandedGroups: Set<String> = ["默认"]
    @State private var showCredGroups: Bool = false
    @State private var contextServer: Server?
    @State private var contextMenuPos: CGPoint = .zero

    private let defaultGroup = "默认"

    var body: some View {
        VStack(spacing: 0) {
            if !appState.sidebarCollapsed {
                addButton
                serverList
                Spacer(minLength: 0)
                credentialSection
            } else {
                collapsedContent
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            if !expandedGroups.contains(defaultGroup) {
                expandedGroups.insert(defaultGroup)
            }
        }
    }

    private var addButton: some View {
        Button(action: { appState.openDialog() }) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                Text("添加服务器")
                    .font(.system(size: 13))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var serverList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let groups = Dictionary(grouping: appState.servers) { $0.group_name.isEmpty ? defaultGroup : $0.group_name }
                ForEach(groups.keys.sorted(), id: \.self) { groupName in
                    groupSection(groupName: groupName, servers: groups[groupName] ?? [])
                }
            }
        }
    }

    private func groupSection(groupName: String, servers: [Server]) -> some View {
        let isExpanded = expandedGroups.contains(groupName) || groupName == defaultGroup
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: { toggleGroup(groupName) }) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                        Text(groupName)
                            .font(.system(size: 11))
                        Spacer()
                        Text("\(servers.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if groupName != defaultGroup {
                    Button(action: {
                        appState.openDialog(defaults: ServerInput(
                            name: "", host: "", port: 22, group_name: groupName,
                            auth_type: "password", username: "", password: nil,
                            private_key: nil, key_source: "content", key_file_path: nil,
                            key_passphrase: nil, credential_group_id: nil, jump_server_id: nil
                        ))
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            if isExpanded {
                ForEach(servers) { server in
                    serverRow(server)
                }
            }
        }
    }

    private func serverRow(_ server: Server) -> some View {
        let cgName = appState.credentialGroups.first(where: { $0.id == server.credential_group_id })?.name
        return HStack(spacing: 6) {
            Image(systemName: server.isJumpConfigured ? "arrow.triangle.branch" : "server.rack")
                .foregroundStyle(server.isJumpConfigured ? .cyan : .green)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let cgName = cgName {
                    Text(cgName)
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                        .lineLimit(1)
                } else {
                    Text("\(server.username)@\(server.host):\(server.port)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            appState.addTab(server: server, type: .terminal)
        }
        .contextMenu {
            Button("SSH 终端") { appState.addTab(server: server, type: .terminal) }
            Button("SFTP 文件管理") { appState.addTab(server: server, type: .sftp) }
            Button("资源监控") { appState.addTab(server: server, type: .monitor) }
            Divider()
            Button("编辑") { appState.openDialog(server: server) }
            Button("删除", role: .destructive) { appState.deleteServer(server.id) }
        }
    }

    private var credentialSection: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: { showCredGroups.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: showCredGroups ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                    Image(systemName: "key.round")
                        .font(.system(size: 11))
                    Text("凭据分组")
                        .font(.system(size: 11))
                    Spacer()
                    Text("\(appState.credentialGroups.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if showCredGroups {
                ForEach(appState.credentialGroups) { cg in
                    HStack(spacing: 6) {
                        Image(systemName: "key.round")
                            .foregroundStyle(.purple)
                            .font(.system(size: 11))
                        Text(cg.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Button(action: { appState.openCgDialog(cg) }) {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        Button(action: { appState.deleteCg(cg.id) }) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
                Button(action: { appState.openCgDialog() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                        Text("新建凭据分组")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    private var collapsedContent: some View {
        VStack(spacing: 4) {
            Button(action: { appState.openDialog() }) {
                Image(systemName: "plus")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("添加服务器")
            .padding(.vertical, 4)

            ForEach(appState.servers) { server in
                Button(action: { appState.addTab(server: server, type: .terminal) }) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(server.name)
                .padding(.vertical, 2)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func toggleGroup(_ name: String) {
        if expandedGroups.contains(name) {
            expandedGroups.remove(name)
        } else {
            expandedGroups.insert(name)
        }
    }
}
