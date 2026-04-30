import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var hoveredServerId: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 50)
                    .padding(.bottom, 32)

                if !groupedServers.isEmpty {
                    serverGrid
                        .padding(.horizontal, 48)
                }

                if appState.servers.isEmpty {
                    emptyHint
                        .padding(.top, 60)
                }

                Spacer(minLength: 60)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if appState.servers.isEmpty {
                appState.loadServers()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Text("Orbit")
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            Text("快速连接你的服务器")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                quickActionButton("本地终端", icon: "terminal") {
                    appState.addLocalTerminalTab()
                }
                quickActionButton("添加服务器", icon: "plus.circle") {
                    appState.openDialog()
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Server grid

    private var groupedServers: [(String, [Server])] {
        let groups = Dictionary(grouping: appState.servers) { $0.group_name.isEmpty ? "默认" : $0.group_name }
        return groups.sorted { $0.key < $1.key }
    }

    private var serverGrid: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(groupedServers, id: \.0) { groupName, servers in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                        Text(groupName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("\(servers.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                    }

                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 10)
                    ], spacing: 10) {
                        ForEach(servers) { server in
                            serverCard(server)
                        }
                    }
                }
            }
        }
    }

    private func serverCard(_ server: Server) -> some View {
        let isHovered = hoveredServerId == server.id

        return HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(server.host)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if server.port != 22 {
                        Text(":\(server.port)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.quaternary)
                    }
                }
            }

            Spacer()

            // Action buttons — show on hover
            if isHovered {
                HStack(spacing: 4) {
                    actionBtn(icon: "terminal", color: .accentColor) {
                        appState.addTab(server: server, type: .terminal)
                    }
                    actionBtn(icon: "folder", color: .secondary) {
                        appState.addTab(server: server, type: .sftp)
                    }
                    actionBtn(icon: "chart.bar", color: .secondary) {
                        appState.addTab(server: server, type: .monitor)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredServerId = hovering ? server.id : nil
            }
        }
        .onTapGesture(count: 2) {
            appState.addTab(server: server, type: .terminal)
        }
        .contentShape(Rectangle())
    }

    private func actionBtn(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text("还没有服务器")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            Button(action: { appState.openDialog() }) {
                Text("添加服务器")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))
            .clipShape(Capsule())
        }
    }

    // MARK: - Helpers

    private func quickActionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
