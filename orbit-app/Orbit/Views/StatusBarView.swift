import SwiftUI

struct StatusBarView: View {
    let appState: AppState

    var body: some View {
        let context = appState.activeSessionContext

        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(for: context))
                .frame(width: 6, height: 6)

            Text(activeSessionCount == 0 ? "无活动会话" : "已连接 \(activeSessionCount) 个会话")
                .lineLimit(1)

            Spacer()

            Text("⌘K 快速连接 · ⌘⇧P 命令面板")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private var activeSessionCount: Int {
        appState.tabs.reduce(into: 0) { count, tab in
            if let paneTree = tab.paneTree {
                count += paneTree.channelIds.count
            } else if tab.sessionId != nil {
                count += 1
            }
        }
    }

    private func statusColor(for context: ActiveSessionContext) -> Color {
        switch context.connectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .failed:
            return .red
        case .closing:
            return .yellow
        case .disconnected:
            return .secondary
        }
    }
}
