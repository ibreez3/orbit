import SwiftUI

struct SessionToolDockView: View {
    @EnvironmentObject var toolState: ToolState
    @EnvironmentObject var inventoryState: InventoryState
    @EnvironmentObject var aiState: AIState
    let appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            dockButton(.ai, symbol: "sparkles", title: "AI 助手")
            dockButton(.sftp, symbol: "folder", title: "文件管理")
            dockButton(.monitor, symbol: "waveform.path.ecg", title: "监控")
            dockButton(.snippets, symbol: "text.insert", title: "命令片段")
            dockButton(.logs, symbol: "list.bullet.rectangle", title: "日志")

            Spacer()


        }
        .padding(.vertical, 10)
        .frame(width: 52)
        .background(Color.black.opacity(0.16))
    }

    private func dockButton(_ tool: SessionTool, symbol: String, title: String) -> some View {
        let disabledReason = appState.canOpenTool(tool)
        let isActive = toolState.activeTool?.tool == tool || (tool == .ai && toolState.aiPanelOpen)

        return Button(action: {
            if tool == .ai {
                appState.toggleAIDrawerForCurrentContext()
            } else {
                appState.openTool(tool)
            }
        }) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabledReason != nil)
        .foregroundStyle(disabledReason == nil ? (isActive ? Color.accentColor : Color.secondary) : Color.secondary.opacity(0.35))
        .help(disabledReason ?? title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("dock-\(tool.rawValue)")
    }

}
