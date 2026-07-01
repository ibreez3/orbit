import SwiftUI

struct SessionToolDockView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            dockButton(.ai, symbol: "sparkles", title: "AI")
            dockButton(.sftp, symbol: "folder", title: "SFTP")
            dockButton(.monitor, symbol: "waveform.path.ecg", title: "Monitor")
            dockButton(.snippets, symbol: "text.insert", title: "Snippets")
            dockButton(.logs, symbol: "list.bullet.rectangle", title: "Logs")

            Button(action: openDockerTab) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(activeServer() == nil)
            .foregroundStyle(activeServer() == nil ? Color.secondary.opacity(0.35) : Color.secondary)
            .help(activeServer() == nil ? "选择远端服务器后可用 Docker" : "Docker")

            Button(action: openDatabaseTab) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Database")

            Spacer()

            Button(action: { SettingsWindowController.shared.open(with: appState) }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
        }
        .padding(.vertical, 10)
        .frame(width: 52)
        .background(Color.black.opacity(0.16))
    }

    private func dockButton(_ tool: SessionTool, symbol: String, title: String) -> some View {
        let disabledReason = appState.canOpenTool(tool)
        let isActive = appState.activeTool?.tool == tool || (tool == .ai && appState.aiPanelOpen)

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
    }

    private func activeServer() -> Server? {
        guard let serverId = appState.activeSessionContext.serverId, serverId != "local" else { return nil }
        return appState.servers.first(where: { $0.id == serverId })
    }

    private func openDockerTab() {
        guard let server = activeServer() else { return }
        appState.addTab(server: server, type: .docker)
    }

    private func openDatabaseTab() {
        let id = "database-\(Int(Date().timeIntervalSince1970 * 1000))"
        let context = appState.activeSessionContext
        let serverId = context.serverId ?? "database"
        let serverName = context.serverName ?? "Database"
        let tab = TabItem(id: id, type: .database, serverId: serverId, serverName: serverName, title: "Database")
        appState.tabs.append(tab)
        appState.requestActivateTab(id)
    }
}
