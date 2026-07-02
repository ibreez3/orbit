import SwiftUI

struct MainView: View {
    @StateObject private var appState: AppState
    @ObservedObject private var tabState: TabState
    @ObservedObject private var uiState: UIState
    @ObservedObject private var themeState: ThemeState
    @ObservedObject private var inventoryState: InventoryState
    @ObservedObject private var toolState: ToolState
    @State private var batchExecutionVisible: Bool = false

    init(appState: AppState = AppState()) {
        _appState = StateObject(wrappedValue: appState)
        _tabState = ObservedObject(wrappedValue: appState.tabState)
        _uiState = ObservedObject(wrappedValue: appState.uiState)
        _themeState = ObservedObject(wrappedValue: appState.themeState)
        _inventoryState = ObservedObject(wrappedValue: appState.inventoryState)
        _toolState = ObservedObject(wrappedValue: appState.toolState)
    }

    var body: some View {
        let base = ZStack {
            mainLayout
            spotlightOverlay
            quitConfirmationOverlay
            terminalCloseConfirmationOverlay
        }
        .frame(minWidth: 900, minHeight: 600)
        .environmentObject(appState.tabState)
        .environmentObject(appState.uiState)
        .environmentObject(appState.themeState)
        .environmentObject(appState.inventoryState)
        .environmentObject(appState.snippetState)
        .environmentObject(appState.toolState)
        .environmentObject(appState.aiState)
        .environmentObject(appState.sftpDrawer)
        .sheet(isPresented: Binding(
            get: { uiState.dialogOpen },
            set: { if !$0 { appState.closeDialog() } }
        )) {
            ServerDialog(appState: appState)
                .environmentObject(appState.inventoryState)
        }
        .sheet(isPresented: Binding(
            get: { uiState.cgDialogOpen },
            set: { if !$0 { appState.closeCgDialog() } }
        )) {
            CredentialGroupDialog(appState: appState)
                .environmentObject(appState.inventoryState)
        }
        .sheet(isPresented: Binding(
            get: { batchExecutionVisible },
            set: { batchExecutionVisible = $0 }
        )) {
            BatchExecutionView(appState: appState)
                .environmentObject(appState.inventoryState)
        }
        .modifier(AlertModifier(appState: appState, uiState: uiState))
        .alert("确认切换会话", isPresented: Binding(
            get: { toolState.pendingContextSwitchTabId != nil },
            set: { if !$0 { appState.cancelPendingContextSwitch() } }
        )) {
            Button("继续切换", role: .destructive) {
                appState.confirmPendingContextSwitch()
            }
            Button("取消", role: .cancel) {
                appState.cancelPendingContextSwitch()
            }
        } message: {
            Text(toolState.pendingContextSwitchMessage ?? "")
        }
        .onAppear {
            if inventoryState.servers.isEmpty { appState.loadServers() }
            if inventoryState.credentialGroups.isEmpty { appState.loadCredentialGroups() }
        }

        return base
            .onExitCommand {
                if toolState.activeTool?.tool != .ai {
                    appState.closeOverlayTool()
                }
            }
            .onReceive(nc(.newTerminal)) { _ in appState.openSpotlight() }
            .onReceive(nc(.openSpotlight)) { _ in appState.openSpotlight() }
            .onReceive(nc(.splitHorizontal)) { _ in appState.splitCurrentPane(direction: .horizontal) }
            .onReceive(nc(.splitVertical)) { _ in appState.splitCurrentPane(direction: .vertical) }
            .onReceive(nc(.closePane)) { _ in appState.closeCurrentPane() }
            .onReceive(nc(.navigatePrevPane)) { _ in appState.navigatePane(forward: false) }
            .onReceive(nc(.navigateNextPane)) { _ in appState.navigatePane(forward: true) }
            .onReceive(nc(.growPane)) { _ in appState.resizePane(grow: true) }
            .onReceive(nc(.shrinkPane)) { _ in appState.resizePane(grow: false) }
            .modifier(SftpDrawerModifier(appState: appState))
            .modifier(ClearScreenModifier(appState: appState))
            .modifier(FindInTerminalModifier(appState: appState))
            .modifier(ReconnectModifier(appState: appState))
            .onReceive(nc(.openSettings)) { _ in SettingsWindowController.shared.open(with: appState) }
            .onReceive(nc(.toggleAIPanel)) { _ in appState.toggleAIPanel() }
            .onReceive(nc(.openBatchExecution)) { _ in batchExecutionVisible = true }
    }

    private func nc(_ name: Notification.Name) -> NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: name)
    }

    private var mainLayout: some View {
        HStack(spacing: 0) {
            AssetTreeView(appState: appState)
                .frame(width: uiState.assetTreeWidth)

            resizeHandle

            Divider()

            VStack(spacing: 0) {
                TabBarView(appState: appState)
                ZStack(alignment: .topTrailing) {
                    contentArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.closeOverlayTool()
                        }

                    SessionToolOverlayView(appState: appState)
                }
                StatusBarView(appState: appState)
            }

            if toolState.aiPanelOpen {
                Divider()
                AIChatView(appState: appState)
            }

            Divider()
            SessionToolDockView(appState: appState)
        }
        .background(themeWindowColor)
        .preferredColorScheme(themeColorScheme)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.0))
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newWidth = uiState.assetTreeWidth + value.translation.width
                        uiState.assetTreeWidth = min(350, max(160, newWidth))
                    }
                    .onEnded { _ in
                        appState.saveAssetTreeWidth(uiState.assetTreeWidth)
                    }
            )
    }

    private var themeWindowColor: Color {
        let tc = ThemeColors.colors(for: themeState.theme)
        return Color(red: tc.windowBg.red, green: tc.windowBg.green, blue: tc.windowBg.blue)
    }

    private var themeColorScheme: ColorScheme {
        let tc = ThemeColors.colors(for: themeState.theme)
        let luminance = 0.299 * tc.foreground.red + 0.587 * tc.foreground.green + 0.114 * tc.foreground.blue
        return luminance > 0.5 ? .dark : .light
    }

    @ViewBuilder
    private var contentArea: some View {
        if let activeTab = tabState.tabs.first(where: { $0.id == tabState.activeTabId }) {
            if let tree = activeTab.paneTree {
                SplitPaneView(node: tree, serverId: activeTab.serverId, tabId: activeTab.id, appState: appState)
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
            ZStack(alignment: .bottomTrailing) {
                TerminalView(channelId: tab.sessionId, serverId: tab.serverId, tabId: tab.id, appState: appState)
                    .id(tab.id)
                if tabState.activeTabError != nil, tab.id == tabState.activeTabId {
                    AIErrorBanner(errorText: tabState.activeTabError!, appState: appState)
                        .padding(12)
                }
            }
        case .sftp:
            SftpView(tab: tab, appState: appState)
                .id(tab.id)
        case .monitor:
            MonitorView(tab: tab, appState: appState)
                .id(tab.id)
        case .database:
            DatabaseView(tab: tab, appState: appState)
                .id(tab.id)
        case .docker:
            DockerView(appState: appState, tab: tab)
                .id(tab.id)
        }
    }

    private var emptyState: some View {
        HomeView(appState: appState)
    }

    @ViewBuilder
    private var spotlightOverlay: some View {
        if uiState.spotlightOpen {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { appState.closeSpotlight() }

                SpotlightView(appState: appState)
            }
        }
    }

    @ViewBuilder
    private var terminalCloseConfirmationOverlay: some View {
        if let tab = pendingCloseTab {
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { appState.cancelCloseTab() }

                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 32, height: 32)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("关闭终端")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)

                            Text("此操作会断开当前 SSH 连接。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)

                        Text("终端会话将被关闭，正在运行的交互命令也会随连接一起结束。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 10) {
                        Spacer()

                        Button("取消") {
                            appState.cancelCloseTab()
                        }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 7))

                        Button("关闭终端") {
                            appState.confirmCloseTab()
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.9))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(22)
                .frame(width: 360)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var quitConfirmationOverlay: some View {
        if uiState.showQuitConfirmation {
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

    private var pendingCloseTab: TabItem? {
        guard let id = uiState.pendingCloseTabId else { return nil }
        return tabState.tabs.first { $0.id == id }
    }
}

private struct SftpDrawerModifier: ViewModifier {
    let appState: AppState
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .toggleSftpDrawer)) { _ in
            if let activeId = appState.activeTabId,
               let tab = appState.tabs.first(where: { $0.id == activeId }),
               tab.type == .terminal {
                appState.openTool(.sftp)
            }
        }
    }
}

private struct ClearScreenModifier: ViewModifier {
    let appState: AppState
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .clearScreen)) { _ in
            if let activeId = appState.activeTabId,
               let tab = appState.tabs.first(where: { $0.id == activeId }),
               let sid = tab.focusedChannelId ?? tab.sessionId,
               let tv = OrbitBridge.shared.terminalView(for: sid) as? OrbitTerminalView {
                let term = tv.getTerminal()
                term.buffer.clear()
                tv.setNeedsDisplay(tv.bounds)
            }
        }
    }
}

private struct FindInTerminalModifier: ViewModifier {
    let appState: AppState
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .findInTerminal)) { _ in
            if let activeId = appState.activeTabId,
               let tab = appState.tabs.first(where: { $0.id == activeId }),
               let sid = tab.focusedChannelId ?? tab.sessionId,
               let tv = OrbitBridge.shared.terminalView(for: sid) as? OrbitTerminalView {
                tv.performFindPanelAction(NSTextFinder.Action.showFindInterface.rawValue)
            }
        }
    }
}

private struct ReconnectModifier: ViewModifier {
    let appState: AppState
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .reconnectSession)) { _ in
            if let activeId = appState.activeTabId,
               let tab = appState.tabs.first(where: { $0.id == activeId }),
               tab.type == .terminal {
                appState.reconnectTab(activeId)
            }
        }
    }
}

private struct AlertModifier: ViewModifier {
    let appState: AppState
    @ObservedObject var uiState: UIState

    func body(content: Content) -> some View {
        content.alert(uiState.alertTitle, isPresented: Binding(
            get: { uiState.alertMessage != nil },
            set: { if !$0 { appState.alertMessage = nil } }
        )) {
            Button("确定") { appState.alertMessage = nil }
        } message: {
            Text(uiState.alertMessage ?? "")
        }
    }
}
