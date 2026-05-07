import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo and title
            VStack(spacing: 12) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text("欢迎回来")
                    .font(.system(size: 24, weight: .semibold))

                Text("选择一个服务器开始工作")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 32)

            // Quick actions
            HStack(spacing: 16) {
                QuickActionButton(
                    icon: "terminal",
                    label: "本地终端",
                    shortcut: "⌘N",
                    action: { appState.addLocalTerminalTab() }
                )
                QuickActionButton(
                    icon: "plus",
                    label: "添加服务器",
                    shortcut: "⌘+",
                    action: { appState.openDialog() }
                )
                QuickActionButton(
                    icon: "sparkles",
                    label: "AI 助手",
                    shortcut: "⌘I",
                    action: { appState.toggleAIPanel() }
                )
                QuickActionButton(
                    icon: "magnifyingglass",
                    label: "命令面板",
                    shortcut: "⌘K",
                    action: { appState.openSpotlight() }
                )
            }
            .padding(.bottom, 40)

            // Recent servers
            if !recentServerList.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("最近连接")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280))], spacing: 8) {
                        ForEach(recentServerList, id: \.id) { server in
                            RecentServerCard(server: server)
                        }
                    }
                }
                .frame(maxWidth: 600)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recentServerList: [Server] {
        appState.recentServers.compactMap { id in
            appState.servers.first { $0.id == id }
        }
    }
}

// MARK: - Quick Action Button

private struct QuickActionButton: View {
    let icon: String
    let label: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 12))
                Text(shortcut)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 90, height: 90)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recent Server Card

private struct RecentServerCard: View {
    let server: Server
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button(action: {
            appState.addTab(server: server, type: .terminal)
        }) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("\(server.host):\(server.port)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
