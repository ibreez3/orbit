import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            if let activeTab = activeTab {
                Text(activeTab.serverName)
                    .lineLimit(1)
                if activeTab.type == .database {
                    Text("· 只读")
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("无连接")
            }

            Spacer()

            Text("⌘K 搜索")
            Text("⌘, 设置")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private var activeTab: TabItem? {
        appState.tabs.first(where: { $0.id == appState.activeTabId })
    }

    private var statusColor: Color {
        guard let tab = activeTab else { return .secondary }
        if tab.type == .terminal || tab.type == .sftp {
            return tab.sessionId != nil ? .green : .secondary
        }
        return .green
    }
}
