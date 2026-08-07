import SwiftUI

struct HomeView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                RecentConnectionsView(appState: appState)

                HStack(spacing: 12) {
                    HomeActionButton(
                        icon: "terminal",
                        label: "本地终端",
                        action: { appState.addLocalTerminalTab() }
                    )
                    HomeActionButton(
                        icon: "plus",
                        label: "添加服务器",
                        action: { appState.openDialog() }
                    )
                    HomeActionButton(
                        icon: "magnifyingglass",
                        label: "命令面板",
                        action: { appState.openWorkspaceEntry(.commandPalette) }
                    )
                }
                .frame(minWidth: 360, idealWidth: 390, maxWidth: 420)
            }
            .frame(maxWidth: 800)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            appState.loadServers()
        }
    }
}

private struct HomeActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
