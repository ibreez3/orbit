import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let context = appState.activeSessionContext

        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(for: context))
                .frame(width: 6, height: 6)

            Text(context.serverName ?? "无活动会话")
                .lineLimit(1)

            if let tool = appState.activeTool?.tool {
                Text("· \(tool.rawValue)")
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text("⌘K 搜索")
            Text("Dock 工具绑定当前会话")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
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
