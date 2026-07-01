import SwiftUI
import AppKit

// MARK: - Selectable item types

enum SpotlightItem: Identifiable {
    case server(Server)
    case credential(CredentialGroup)
    case action(String, String, () -> Void)

    var id: String {
        switch self {
        case .server(let s): return "s-\(s.id)"
        case .credential(let c): return "c-\(c.id)"
        case .action(let title, _, _): return "a-\(title)"
        }
    }
}

// MARK: - SpotlightView

struct SpotlightView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isSearchFocused: Bool
    @State private var selectedIndex: Int = 0
    @State private var keyMonitor: Any? = nil

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
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: appState.spotlightQuery) { _ in
            selectedIndex = 0
        }
    }

    // MARK: - Keyboard monitor (macOS 13 compatible)

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only intercept when spotlight is open
            guard appState.spotlightOpen else { return event }
            switch event.keyCode {
            case 126: // up arrow
                moveSelection(-1)
                return nil
            case 125: // down arrow
                moveSelection(1)
                return nil
            case 36: // return
                confirmSelection()
                return nil
            case 53: // escape
                appState.closeSpotlight()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Flattened items

    private var allItems: [SpotlightItem] {
        var items: [SpotlightItem] = []
        for s in filteredServers {
            items.append(.server(s))
        }
        if !appState.credentialGroups.isEmpty {
            for c in filteredCredentials {
                items.append(.credential(c))
            }
        }
        items.append(.action("添加服务器", "plus.circle") {
            appState.closeSpotlight()
            appState.openDialog()
        })
        items.append(.action("添加数据库连接", "cylinder") {
            appState.closeSpotlight()
        })
        items.append(.action("新建凭证", "key.badge.plus") {
            appState.closeSpotlight()
            appState.openCgDialog()
        })
        items.append(.action("切换主题", "circle.lefthalf.filled") {
            let allCases = AppTheme.allCases
            if let idx = allCases.firstIndex(of: appState.theme) {
                appState.setTheme(allCases[(idx + 1) % allCases.count])
            }
            appState.closeSpotlight()
        })
        return items
    }

    // MARK: - Search field

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

    // MARK: - Results list with sections

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    serversSection
                    if !appState.credentialGroups.isEmpty || !filteredCredentials.isEmpty {
                        credentialsSection
                    }
                    quickActionsSection
                }
            }
            .onChange(of: selectedIndex) { idx in
                let items = allItems
                guard idx >= 0, idx < items.count else { return }
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(items[idx].id, anchor: .center)
                }
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
                        let idx = allItems.firstIndex(where: { if case .server(let s) = $0 { return s.id == server.id } else { return false } })
                        serverRow(server, isSelected: idx == selectedIndex)
                            .id(SpotlightItem.server(server).id)
                    }
                }
            }
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("凭证", icon: "key.round")
            ForEach(filteredCredentials) { cg in
                let idx = allItems.firstIndex(where: { if case .credential(let c) = $0 { return c.id == cg.id } else { return false } })
                credentialRow(cg, isSelected: idx == selectedIndex)
                    .id(SpotlightItem.credential(cg).id)
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("快捷操作", icon: "bolt")
            let actions: [(String, String, () -> Void)] = [
                ("添加服务器", "plus.circle", { appState.closeSpotlight(); appState.openDialog() }),
                ("添加数据库连接", "cylinder", { appState.closeSpotlight() }),
                ("新建凭证", "key.badge.plus", { appState.closeSpotlight(); appState.openCgDialog() }),
                ("切换主题", "circle.lefthalf.filled", {
                    let allCases = AppTheme.allCases
                    if let idx = allCases.firstIndex(of: appState.theme) {
                        appState.setTheme(allCases[(idx + 1) % allCases.count])
                    }
                    appState.closeSpotlight()
                }),
            ]
            ForEach(actions, id: \.0) { title, icon, action in
                let idx = allItems.firstIndex(where: { if case .action(let t, _, _) = $0 { return t == title } else { return false } })
                actionRow(title, icon: icon, isSelected: idx == selectedIndex, action: action)
                    .id(SpotlightItem.action(title, icon, {}).id)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("↑↓ 导航")
            Text("↵ 确认")
            Text("⌘N 新建服务器")
            Spacer()
            Text("单击 → SSH  |  文件夹按钮 → SFTP 抽屉")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Section headers

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

    // MARK: - Row views with selection highlight

    private func serverRow(_ server: Server, isSelected: Bool) -> some View {
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
                openSftpDrawer(for: server)
            }) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("打开 SFTP 抽屉")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.addTab(server: server, type: .terminal)
            appState.closeSpotlight()
        }
    }

    private func credentialRow(_ cg: CredentialGroup, isSelected: Bool) -> some View {
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
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.openCgDialog(cg)
            appState.closeSpotlight()
        }
    }

    private func actionRow(_ title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
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
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }

    // MARK: - Keyboard navigation

    private func moveSelection(_ delta: Int) {
        let count = allItems.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    private func confirmSelection() {
        let items = allItems
        guard selectedIndex >= 0, selectedIndex < items.count else { return }
        let item = items[selectedIndex]
        switch item {
        case .server(let server):
            appState.addTab(server: server, type: .terminal)
            appState.closeSpotlight()
        case .credential(let cg):
            appState.openCgDialog(cg)
            appState.closeSpotlight()
        case .action(_, _, let action):
            action()
        }
    }

    // MARK: - SFTP drawer connection (P0-3)

    private func openSftpDrawer(for server: Server) {
        if let existingTab = appState.tabs.first(where: { $0.type == .terminal && $0.serverId == server.id }) {
            if appState.requestActivateTab(existingTab.id) {
                appState.openTool(.sftp)
            }
        } else {
            appState.addTab(server: server, type: .terminal)
            if let newTab = appState.tabs.last {
                if appState.requestActivateTab(newTab.id) {
                    appState.openTool(.sftp)
                }
            }
        }
        appState.closeSpotlight()
    }

    // MARK: - Filtering

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
