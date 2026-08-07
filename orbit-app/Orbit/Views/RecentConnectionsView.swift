import SwiftUI

struct RecentConnectionsView: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject var inventoryState: InventoryState
    @EnvironmentObject var tabState: TabState
    @EnvironmentObject var uiState: UIState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近连接")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                if !rows.isEmpty {
                    Button("查看全部") {
                        appState.selectServerSystemView(.all)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: 24)

            if rows.isEmpty {
                Text("暂无连接记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .background(Color.primary.opacity(0.025))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(8).enumerated()), id: \.element.id) { index, row in
                        RecentConnectionRowView(
                            row: row,
                            label: organizationLabel(for: row.server),
                            folders: appState.serverOrganization.folders,
                            appState: appState
                        )

                        if index < min(rows.count, 8) - 1 {
                            Divider()
                                .padding(.leading, 34)
                        }
                    }
                }
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var rows: [RecentConnectionRow] {
        RecentConnectionProjector.rows(
            servers: inventoryState.servers,
            activeServerIds: activeServerIds,
            legacyIds: uiState.recentServers
        )
    }

    private var activeServerIds: Set<String> {
        Set(tabState.tabs.compactMap { tab in
            guard tab.type == .terminal,
                  tab.sessionId != nil,
                  case .saved(let serverId) = tab.connectionTarget else {
                return nil
            }
            return serverId
        })
    }

    private func organizationLabel(for server: Server) -> String? {
        if let folderId = server.folder_id,
           let folder = appState.serverOrganization.folders.first(where: { $0.id == folderId }) {
            return folder.name
        }

        let tagIds = Set(
            appState.serverOrganization.tag_links
                .filter { $0.server_id == server.id }
                .map(\.tag_id)
        )
        return appState.serverOrganization.tags
            .filter { tagIds.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .first?
            .name
    }
}

private struct RecentConnectionRowView: View {
    let row: RecentConnectionRow
    let label: String?
    let folders: [ServerFolder]
    let appState: AppState

    @State private var isHovered = false

    var body: some View {
        Button {
            appState.addTab(server: row.server, type: .terminal)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .help(row.statusLabel)
                    .accessibilityLabel(row.statusLabel)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if row.server.is_pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }

                        Text(row.server.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)

                        if let label {
                            Text(label)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(Capsule())
                        }
                    }

                    Text("\(row.server.host):\(row.server.port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(row.relativeTime)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Color.clear
                    .frame(width: 28, height: 28)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 56)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if isHovered {
                actionMenu
                    .padding(.trailing, 10)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(row.server.name)，\(row.server.host):\(row.server.port)，\(row.statusLabel)，\(row.relativeTime)")
    }

    private var actionMenu: some View {
        Menu {
            Button("连接") {
                appState.addTab(server: row.server, type: .terminal)
            }

            Button("编辑") {
                appState.openDialog(server: row.server)
            }

            Button(row.server.is_pinned ? "取消置顶" : "置顶") {
                appState.setServerPinned(row.server, isPinned: !row.server.is_pinned)
            }

            Menu("移动到") {
                Button("未分类") {
                    appState.moveServer(row.server, toFolderId: nil)
                }

                if !folders.isEmpty {
                    Divider()
                }

                ForEach(folders.sorted(by: folderOrder)) { folder in
                    Button(folder.name) {
                        appState.moveServer(row.server, toFolderId: folder.id)
                    }
                }
            }

            Divider()

            Button("删除", role: .destructive) {
                appState.deleteServer(row.server.id)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("\(row.server.name) 更多操作")
    }

    private var statusColor: Color {
        switch row.status {
        case .active:
            return .green
        case .failed:
            return .red
        case .unknown:
            return .gray
        }
    }

    private func folderOrder(_ lhs: ServerFolder, _ rhs: ServerFolder) -> Bool {
        if lhs.sort_order != rhs.sort_order {
            return lhs.sort_order < rhs.sort_order
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
