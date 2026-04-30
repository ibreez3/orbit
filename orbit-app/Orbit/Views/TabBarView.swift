import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(appState.tabs) { tab in
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

            Button(action: {}) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
            }
            .buttonStyle(.plain)
            .help("Network status")

            Button(action: { appState.addTab(server: Server.placeholder, type: .settings) }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func tabPill(_ tab: TabItem) -> some View {
        let isActive = tab.id == appState.activeTabId
        return HStack(spacing: 5) {
            Circle()
                .fill(connectionColor(tab))
                .frame(width: 6, height: 6)
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
            if isActive {
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
        .onTapGesture { appState.activeTabId = tab.id }
        .onTapGesture(count: 2) {
            if tab.type == .terminal {
                appState.toggleSftpDrawer(for: tab.id)
            }
        }
    }

    private func connectionColor(_ tab: TabItem) -> Color {
        if tab.sessionId != nil { return .green }
        return .secondary
    }

    private func closeTab(_ tab: TabItem) {
        if tab.type == .terminal, tab.sessionId != nil {
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
