import SwiftUI

struct SpotlightView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(maxHeight: 520)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onAppear { isSearchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField("搜索服务器、数据库、凭证、命令…", text: $appState.spotlightQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isSearchFocused)
            Button(action: { appState.closeSpotlight() }) {
                Text("Esc")
                    .font(.system(size: 11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                serversSection
                if !appState.credentialGroups.isEmpty {
                    credentialsSection
                }
                quickActionsSection
            }
        }
    }

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("服务器", icon: "server.rack")
            let groups = Dictionary(grouping: filteredServers) { $0.group_name.isEmpty ? "默认" : $0.group_name }
            ForEach(groups.keys.sorted(), id: \.self) { groupName in
                if let servers = groups[groupName] {
                    groupRow(name: groupName, count: servers.count)
                    ForEach(servers) { server in
                        serverRow(server)
                    }
                }
            }
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("凭证", icon: "key.round")
            ForEach(filteredCredentials) { cg in
                credentialRow(cg)
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("快捷操作", icon: "bolt")
            actionRow("添加服务器", icon: "plus.circle") {
                appState.closeSpotlight()
                appState.openDialog()
            }
            actionRow("添加数据库连接", icon: "cylinder") {
                appState.closeSpotlight()
            }
            actionRow("新建凭证", icon: "key.badge.plus") {
                appState.closeSpotlight()
                appState.openCgDialog()
            }
            actionRow("切换主题", icon: "circle.lefthalf.filled") {
                appState.closeSpotlight()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("↑↓ 导航")
            Text("↵ 确认")
            Text("⌘N 新建服务器")
            Spacer()
            Text("双击 → SSH")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func groupRow(name: String, count: Int) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .foregroundStyle(.secondary)
    }

    private func serverRow(_ server: Server) -> some View {
        HStack(spacing: 8) {
            Image(systemName: server.isJumpConfigured ? "arrow.triangle.branch" : "server.rack")
                .foregroundStyle(server.isJumpConfigured ? .cyan : .green)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(server.name)
                .font(.system(size: 13))
            Text(server.host)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: {
                appState.addTab(server: server, type: .sftp)
                appState.closeSpotlight()
            }) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("打开 SFTP")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.addTab(server: server, type: .terminal)
            appState.closeSpotlight()
        }
    }

    private func credentialRow(_ cg: CredentialGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.round")
                .foregroundStyle(.purple)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(cg.name)
                .font(.system(size: 13))
            Text(cg.auth_type)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.openCgDialog(cg)
            appState.closeSpotlight()
        }
    }

    private func actionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredServers: [Server] {
        let q = appState.spotlightQuery.lowercased()
        if q.isEmpty { return appState.servers }
        return appState.servers.filter {
            $0.name.lowercased().contains(q) ||
            $0.host.lowercased().contains(q) ||
            $0.group_name.lowercased().contains(q)
        }
    }

    private var filteredCredentials: [CredentialGroup] {
        let q = appState.spotlightQuery.lowercased()
        if q.isEmpty { return appState.credentialGroups }
        return appState.credentialGroups.filter {
            $0.name.lowercased().contains(q)
        }
    }
}
