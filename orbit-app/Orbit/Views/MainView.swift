import SwiftUI

struct MainView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        ZStack {
            mainLayout
            spotlightOverlay
            quitConfirmationOverlay
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
            // Ensure bridge is initialized and data loaded
            if appState.servers.isEmpty {
                appState.loadServers()
            }
            if appState.credentialGroups.isEmpty {
                appState.loadCredentialGroups()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTerminal)) { _ in
            appState.openSpotlight()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSpotlight)) { _ in
            appState.openSpotlight()
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
        .onReceive(NotificationCenter.default.publisher(for: .toggleSftpDrawer)) { _ in
            if let activeId = appState.activeTabId,
               let tab = appState.tabs.first(where: { $0.id == activeId }),
               tab.type == .terminal {
                appState.toggleSftpDrawer(for: activeId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearScreen)) { _ in
            if let activeId = appState.activeTabId,
               let tab = appState.tabs.first(where: { $0.id == activeId }),
               let sid = tab.sessionId ?? tab.focusedChannelId,
               let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView {
                let term = tv.getTerminal()
                term.buffer.clear()
                tv.setNeedsDisplay(tv.bounds)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .findInTerminal)) { _ in
            if let activeId = appState.activeTabId,
               let tab = appState.tabs.first(where: { $0.id == activeId }),
               let sid = tab.sessionId ?? tab.focusedChannelId,
               let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView {
                tv.performFindPanelAction(NSTextFinder.Action.showFindInterface.rawValue)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            if let existing = appState.tabs.first(where: { $0.type == .settings }) {
                appState.activeTabId = existing.id
            } else {
                appState.addTab(server: Server.placeholder, type: .settings)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reconnectSession)) { _ in
            if let activeId = appState.activeTabId,
               let tab = appState.tabs.first(where: { $0.id == activeId }),
               tab.type == .terminal {
                appState.reconnectTab(activeId)
            }
        }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            TabBarView()
            contentArea
            sftpDrawer
            StatusBarView()
        }
        .background(themeWindowColor)
        .preferredColorScheme(themeColorScheme)
    }

    private var themeWindowColor: Color {
        let tc = ThemeColors.colors(for: appState.theme)
        return Color(red: tc.windowBg.red, green: tc.windowBg.green, blue: tc.windowBg.blue)
    }

    private var themeColorScheme: ColorScheme {
        let tc = ThemeColors.colors(for: appState.theme)
        let luminance = 0.299 * tc.foreground.red + 0.587 * tc.foreground.green + 0.114 * tc.foreground.blue
        return luminance > 0.5 ? .dark : .light
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
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: TabItem) -> some View {
        switch tab.type {
        case .terminal:
            TerminalView(channelId: tab.sessionId, serverId: tab.serverId, tabId: tab.id)
                .id(tab.id)
        case .sftp:
            SftpView(tab: tab)
                .id(tab.id)
        case .monitor:
            MonitorView(tab: tab)
                .id(tab.id)
        case .database:
            DatabaseView(tab: tab)
                .id(tab.id)
        case .settings:
            SettingsView()
        }
    }

    @ViewBuilder
    private var sftpDrawer: some View {
        if let drawerTabId = appState.sftpDrawerTabId,
           let tab = appState.tabs.first(where: { $0.id == drawerTabId }) {
            SftpDrawerView(tab: tab)
        }
    }

    private var emptyState: some View {
        HomeView()
    }

    @ViewBuilder
    private var spotlightOverlay: some View {
        if appState.spotlightOpen {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { appState.closeSpotlight() }

                SpotlightView()
            }
        }
    }

    @ViewBuilder
    private var quitConfirmationOverlay: some View {
        if appState.showQuitConfirmation {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    Image(systemName: "power")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)

                    Text("退出 Orbit")
                        .font(.system(size: 16, weight: .semibold))

                    Text("关闭所有标签页后将退出应用程序。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("取消") {
                            appState.cancelQuit()
                        }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button("退出") {
                            appState.confirmQuit()
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(28)
                .frame(width: 320)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            }
        }
    }
}
