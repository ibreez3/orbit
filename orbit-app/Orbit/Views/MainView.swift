import SwiftUI

struct MainView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        HStack(spacing: 0) {
            sidebarPanel
            mainPanel
        }
        .frame(minWidth: 900, minHeight: 600)
        .environmentObject(appState)
        .sheet(isPresented: Binding(
            get: { appState.dialogOpen },
            set: { if !$0 { appState.closeDialog() } }
        )) {
            ServerDialog()
                .environmentObject(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.cgDialogOpen },
            set: { if !$0 { appState.closeCgDialog() } }
        )) {
            CredentialGroupDialog()
                .environmentObject(appState)
        }
        .onAppear {
            appState.loadServers()
            appState.loadCredentialGroups()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTerminal)) { _ in
            if let server = appState.servers.first {
                appState.addTab(server: server, type: .terminal)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitHorizontal)) { _ in
            appState.splitCurrentPane(direction: .horizontal)
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitVertical)) { _ in
            appState.splitCurrentPane(direction: .vertical)
        }
        .onReceive(NotificationCenter.default.publisher(for: .closePane)) { _ in
            appState.closeCurrentPane()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigatePrevPane)) { _ in
            appState.navigatePane(forward: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateNextPane)) { _ in
            appState.navigatePane(forward: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateLeftPane)) { _ in
            appState.navigatePane(forward: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateRightPane)) { _ in
            appState.navigatePane(forward: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .growPane)) { _ in
            appState.resizePane(grow: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shrinkPane)) { _ in
            appState.resizePane(grow: false)
        }
    }

    private var sidebarPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: { appState.toggleSidebar() }) {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            SidebarView()
        }
        .frame(width: appState.sidebarCollapsed ? 48 : 240)
        .animation(.easeInOut(duration: 0.2), value: appState.sidebarCollapsed)
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            if !appState.tabs.isEmpty {
                tabBar
            }
            contentArea
            statusBar
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(appState.tabs) { tab in
                    tabButton(tab)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func tabButton(_ tab: TabItem) -> some View {
        let isActive = tab.id == appState.activeTabId
        return HStack(spacing: 4) {
            Image(systemName: tabIcon(tab.type))
                .font(.system(size: 11))
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Button(action: { closeTab(tab) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isActive ? .primary : .secondary)
        .background(isActive ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.activeTabId = tab.id }
    }

    @ViewBuilder
    private var contentArea: some View {
        if let activeTab = appState.tabs.first(where: { $0.id == appState.activeTabId }) {
            if let tree = activeTab.paneTree {
                SplitPaneView(node: tree, serverId: activeTab.serverId, tabId: activeTab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabContent(activeTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if appState.tabs.isEmpty {
            emptyState
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: TabItem) -> some View {
        switch tab.type {
        case .terminal:
            TerminalView(channelId: tab.sessionId, serverId: tab.serverId, tabId: tab.id)
        case .sftp:
            SftpView(tab: tab)
        case .monitor:
            MonitorView(tab: tab)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.5))
                .padding(.bottom, -4)

            VStack(spacing: 6) {
                Text("Orbit")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("轻量 SSH 管理终端")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Button(action: { appState.openDialog() }) {
                    Label("添加服务器", systemImage: "plus.circle")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("或双击左侧服务器打开终端")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                Divider()
                    .frame(width: 200)
                HStack(spacing: 16) {
                    shortcut("⌘T", "新建终端")
                    shortcut("⌘N", "添加服务器")
                }
                HStack(spacing: 16) {
                    shortcut("⌘D", "水平分屏")
                    shortcut("⇧⌘D", "垂直分屏")
                }
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(label)
        }
    }

    private var statusBar: some View {
        HStack {
            if let activeTab = appState.tabs.first(where: { $0.id == appState.activeTabId }) {
                Text("\(activeTab.serverName) (\(activeTab.type.rawValue))")
            } else {
                Text("就绪")
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func tabIcon(_ type: TabType) -> String {
        switch type {
        case .terminal: return "terminal"
        case .sftp: return "folder"
        case .monitor: return "chart.xyaxes.line"
        }
    }

    private func closeTab(_ tab: TabItem) {
        if tab.type == .terminal, let sid = tab.sessionId {
            let alert = NSAlert()
            alert.messageText = "确定关闭终端 \"\(tab.title)\" 吗？"
            alert.informativeText = "连接将被断开。"
            alert.addButton(withTitle: "关闭")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            guard let window = NSApp.keyWindow else {
                appState.removeTab(tab.id)
                return
            }
            alert.beginSheetModal(for: window) { resp in
                if resp == .alertFirstButtonReturn {
                    appState.removeTab(tab.id)
                }
            }
        } else {
            appState.removeTab(tab.id)
        }
    }
}
