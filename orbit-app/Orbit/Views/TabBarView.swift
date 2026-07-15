import SwiftUI

struct TabBarView: View {
    let appState: AppState
    @EnvironmentObject var tabState: TabState
    @State private var hoveredTabId: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabState.tabs) { tab in
                        tabPill(tab)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()

            Button(action: { appState.openSpotlight() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Spotlight (⌘K)")
            .accessibilityLabel("打开 Spotlight")

            networkIndicator

            Button(action: { SettingsWindowController.shared.open(with: appState) }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("打开设置")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    // MARK: - Network status indicator

    private var networkIndicator: some View {
        let activeTab = tabState.tabs.first(where: { $0.id == tabState.activeTabId })
        let isConnectionTab = activeTab?.type == .terminal || activeTab?.type == .sftp || activeTab?.type == .monitor

        guard let tab = activeTab, isConnectionTab else {
            return AnyView(
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .frame(width: 28, height: 28)
            )
        }

        let isConnected = tab.sessionId != nil
        return AnyView(
            HStack(spacing: 4) {
                Circle()
                    .fill(isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                if !isConnected {
                    Text("离线")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .help(isConnected ? "\(tab.serverName) 已连接" : "\(tab.serverName) 未连接")
            .frame(width: isConnected ? 28 : nil, height: 28)
        )
    }

    // MARK: - Tab pill

    private func tabPill(_ tab: TabItem) -> some View {
        let isActive = tab.id == tabState.activeTabId
        let isHovered = tab.id == hoveredTabId
        let showClose = isActive || isHovered
        let showSftp = isHovered && tab.type == .terminal
        let showDot = tab.type == .terminal || tab.type == .sftp || tab.type == .monitor

        return HStack(spacing: 5) {
            if showDot {
                Circle()
                    .fill(connectionColor(tab))
                    .frame(width: 6, height: 6)
            }
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)

            if showSftp {
                Button(action: {
                    if appState.requestActivateTab(tab.id) {
                        appState.openTool(.sftp)
                    }
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("打开 SFTP")
            }

            if showClose {
                Button(action: { closeTab(tab) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isActive ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onHover { hovering in
            hoveredTabId = hovering ? tab.id : nil
        }
        .onTapGesture { appState.requestActivateTab(tab.id) }
        .onTapGesture(count: 2) {
            if tab.type == .terminal {
                if appState.requestActivateTab(tab.id) {
                    appState.openTool(.sftp)
                }
            }
        }
    }

    private func connectionColor(_ tab: TabItem) -> Color {
        if tab.sessionId != nil { return .green }
        return .secondary
    }

    private func closeTab(_ tab: TabItem) {
        appState.requestCloseTab(tab)
    }
}

// MARK: - TabItem Identifiable for popover

extension TabItem: Equatable {
    static func == (lhs: TabItem, rhs: TabItem) -> Bool {
        lhs.id == rhs.id
    }
}
