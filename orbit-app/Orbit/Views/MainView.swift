import SwiftUI

struct MainView: View {
    @StateObject private var appState = AppState()
    @State private var batchExecutionVisible: Bool = false

    var body: some View {
        let base = ZStack {
            mainLayout
            spotlightOverlay
            quitConfirmationOverlay
            terminalCloseConfirmationOverlay
        }
        .frame(minWidth: 900, minHeight: 600)
        .environmentObject(appState)
        .environmentObject(appState.sftpDrawer)
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
        .sheet(isPresented: Binding(
            get: { batchExecutionVisible },
            set: { batchExecutionVisible = $0 }
        )) {
            BatchExecutionView()
                .environmentObject(appState)
        }
        .modifier(AlertModifier(appState: appState))
        .alert("确认切换会话", isPresented: Binding(
            get: { appState.pendingContextSwitchTabId != nil },
            set: { if !$0 { appState.cancelPendingContextSwitch() } }
        )) {
            Button("继续切换", role: .destructive) {
                appState.confirmPendingContextSwitch()
            }
            Button("取消", role: .cancel) {
                appState.cancelPendingContextSwitch()
            }
        } message: {
            Text(appState.pendingContextSwitchMessage ?? "")
        }
        .onAppear {
            if appState.servers.isEmpty { appState.loadServers() }
            if appState.credentialGroups.isEmpty { appState.loadCredentialGroups() }
        }

        return base
            .onExitCommand {
                if appState.activeTool?.tool != .ai {
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
            AssetTreeView()
                .environmentObject(appState)
                .frame(width: appState.assetTreeWidth)

            resizeHandle

            Divider()

            VStack(spacing: 0) {
                TabBarView()
                ZStack(alignment: .topTrailing) {
                    contentArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.closeOverlayTool()
                        }

                    SessionToolOverlayView()
                        .environmentObject(appState)
                }
                StatusBarView()
            }

            if appState.aiPanelOpen {
                Divider()
                AIChatView()
                    .environmentObject(appState)
            }

            Divider()
            SessionToolDockView()
                .environmentObject(appState)
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
                        let newWidth = appState.assetTreeWidth + value.translation.width
                        appState.assetTreeWidth = min(350, max(160, newWidth))
                    }
                    .onEnded { _ in
                        appState.saveAssetTreeWidth(appState.assetTreeWidth)
                    }
            )
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
            ZStack(alignment: .bottomTrailing) {
                TerminalView(channelId: tab.sessionId, serverId: tab.serverId, tabId: tab.id)
                    .id(tab.id)
                if appState.activeTabError != nil, tab.id == appState.activeTabId {
                    AIErrorBanner(errorText: appState.activeTabError!)
                        .environmentObject(appState)
                        .padding(12)
                }
            }
        case .sftp:
            SftpView(tab: tab)
                .id(tab.id)
        case .monitor:
            MonitorView(tab: tab)
                .id(tab.id)
        case .database:
            DatabaseView(tab: tab)
                .id(tab.id)
        case .docker:
            DockerView(tab: tab)
                .id(tab.id)
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
    private var terminalCloseConfirmationOverlay: some View {
        if let tab = appState.pendingCloseTab {
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
               let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView {
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
               let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView {
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

    func body(content: Content) -> some View {
        content.alert(appState.alertTitle, isPresented: Binding(
            get: { appState.alertMessage != nil },
            set: { if !$0 { appState.alertMessage = nil } }
        )) {
            Button("确定") { appState.alertMessage = nil }
        } message: {
            Text(appState.alertMessage ?? "")
        }
    }
}
