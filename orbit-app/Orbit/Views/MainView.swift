import SwiftUI

struct MainView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        ZStack {
            mainLayout
            spotlightOverlay
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
            if appState.servers.isEmpty {
                appState.openSpotlight()
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
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            TabBarView()
            contentArea
            sftpDrawer
            StatusBarView()
        }
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
        case .sftp:
            SftpView(tab: tab)
        case .monitor:
            MonitorView(tab: tab)
        case .database:
            DatabaseView(tab: tab)
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
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}
