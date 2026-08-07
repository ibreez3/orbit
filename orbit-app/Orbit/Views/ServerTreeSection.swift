import SwiftUI

struct ServerTreeSection: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var inventoryState: InventoryState
    @EnvironmentObject private var uiState: UIState

    var searchQuery = ""
    var showsHeader = true

    @State private var expandedFolderIds: Set<String> = []
    @State private var selectedTagId: String?
    @State private var folderEditor: FolderEditor?
    @State private var folderName = ""
    @State private var emptyDeletion: ServerFolder?
    @State private var populatedDeletion: ServerFolder?

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header }

            if searchQuery.isEmpty {
                systemViews
                folderTree
                tagFilters
            } else {
                searchResults
            }

            if showsHeader {
                Divider().padding(.leading, 12)
            }
        }
        .alert(folderEditor?.title ?? "目录", isPresented: Binding(
            get: { folderEditor != nil },
            set: { if !$0 { folderEditor = nil } }
        )) {
            TextField("目录名称", text: $folderName)
            Button("确定") { commitFolderEditor() }
            Button("取消", role: .cancel) { folderEditor = nil }
        }
        .alert("删除空目录", isPresented: Binding(
            get: { emptyDeletion != nil },
            set: { if !$0 { emptyDeletion = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let folder = emptyDeletion else { return }
                appState.deleteServerFolder(folder, destinationFolderId: nil, deleteServers: false)
                emptyDeletion = nil
            }
            Button("取消", role: .cancel) { emptyDeletion = nil }
        } message: {
            Text("此目录为空，确认删除？")
        }
        .confirmationDialog("删除非空目录", isPresented: Binding(
            get: { populatedDeletion != nil },
            set: { if !$0 { populatedDeletion = nil } }
        ), titleVisibility: .visible) {
            if let folder = populatedDeletion {
                ForEach(deletionDestinations(for: folder)) { destination in
                    Button("移动服务器到 \(folderPath(destination))") {
                        appState.deleteServerFolder(
                            folder,
                            destinationFolderId: destination.id,
                            deleteServers: false
                        )
                        populatedDeletion = nil
                    }
                }
                Button("连同服务器删除", role: .destructive) {
                    appState.deleteServerFolder(folder, destinationFolderId: nil, deleteServers: true)
                    populatedDeletion = nil
                }
            }
            Button("取消", role: .cancel) { populatedDeletion = nil }
        } message: {
            Text("请选择服务器的目标目录，或连同服务器一起删除。")
        }
    }

    private var projection: ServerTreeProjection {
        ServerTreeProjection(
            snapshot: appState.serverOrganization,
            servers: inventoryState.servers,
            legacyRecentIds: uiState.recentServers
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 11))
                .foregroundStyle(.blue)
            Text("服务器")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button {
                beginCreatingFolder(parentId: nil)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("新建一级目录")
            .accessibilityLabel("新建一级目录")
            Text("\(inventoryState.servers.count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 34)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items.first, parentId: nil)
        }
    }

    private var systemViews: some View {
        VStack(spacing: 0) {
            ForEach(projection.visibleSystemViews, id: \.rawValue) { view in
                Button {
                    selectedTagId = nil
                    appState.selectServerSystemView(view)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: view))
                            .font(.system(size: 10))
                            .frame(width: 14)
                        Text(title(for: view))
                            .font(.system(size: 11))
                        Spacer()
                        Text("\(projection.servers(for: view).count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .background(
                        uiState.selectedServerSystemView == view && selectedTagId == nil
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)

                if uiState.selectedServerSystemView == view && selectedTagId == nil && view != .all {
                    ForEach(projection.servers(for: view)) { server in
                        ServerNodeRow(server: server, appState: appState, indent: 30)
                            .draggable("server:\(server.id)")
                    }
                }
            }
        }
    }

    private var folderTree: some View {
        VStack(spacing: 0) {
            ForEach(projection.roots) { node in
                folderNode(node)
            }
        }
    }

    private func folderNode(_ node: ServerFolderNode) -> AnyView {
        let isExpanded = expandedFolderIds.contains(node.id)
        return AnyView(VStack(spacing: 0) {
            Button {
                if isExpanded { expandedFolderIds.remove(node.id) }
                else { expandedFolderIds.insert(node.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14, height: 28)
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(node.folder.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .help(node.path)
                    Spacer()
                    Text("\(node.servers.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, CGFloat(16 + (node.depth - 1) * 14))
                .padding(.trailing, 12)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .draggable("folder:\(node.id)")
            .dropDestination(for: String.self) { items, _ in
                handleDrop(items.first, parentId: node.id)
            }
            .contextMenu {
                if projection.canCreateChild(in: node.id) {
                    Button("新建子目录") { beginCreatingFolder(parentId: node.id) }
                }
                Button("重命名") { beginRenamingFolder(node.folder) }
                Divider()
                Button("上移") { appState.reorderServerFolder(node.folder, direction: -1) }
                Button("下移") { appState.reorderServerFolder(node.folder, direction: 1) }
                Divider()
                Button("删除", role: .destructive) { requestDeletion(node.folder) }
            }

            if isExpanded {
                ForEach(node.children) { child in
                    folderNode(child)
                }
                ForEach(node.servers) { server in
                    ServerNodeRow(
                        server: server,
                        appState: appState,
                        indent: CGFloat(30 + node.depth * 14)
                    )
                    .draggable("server:\(server.id)")
                }
            }
        })
    }

    @ViewBuilder
    private var tagFilters: some View {
        if !projection.tags.isEmpty {
            HStack {
                Text("标签")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 3)

            ForEach(projection.tags) { tag in
                Button {
                    selectedTagId = selectedTagId == tag.id ? nil : tag.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tag")
                            .font(.system(size: 10))
                        Text(tag.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                        Text("\(projection.servers(tagged: tag.id).count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .background(selectedTagId == tag.id ? Color.accentColor.opacity(0.12) : Color.clear)
                }
                .buttonStyle(.plain)

                if selectedTagId == tag.id {
                    ForEach(projection.servers(tagged: tag.id)) { server in
                        ServerNodeRow(server: server, appState: appState, indent: 30)
                            .draggable("server:\(server.id)")
                    }
                }
            }
        }
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            ForEach(projection.search(searchQuery)) { result in
                VStack(alignment: .leading, spacing: 2) {
                    ServerNodeRow(server: result.server, appState: appState, indent: 12)
                    let context = ([result.path] + result.tags.map { Optional($0.name) }).compactMap { $0 }
                    if !context.isEmpty {
                        Text(context.joined(separator: " · "))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.leading, 26)
                            .help(context.joined(separator: " · "))
                    }
                }
            }
        }
    }

    private func beginCreatingFolder(parentId: String?) {
        folderName = ""
        folderEditor = .create(parentId: parentId)
    }

    private func beginRenamingFolder(_ folder: ServerFolder) {
        folderName = folder.name
        folderEditor = .rename(folder)
    }

    private func commitFolderEditor() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let editor = folderEditor else { return }
        switch editor {
        case .create(let parentId):
            appState.createServerFolder(name: name, parentId: parentId)
        case .rename(let folder):
            appState.renameServerFolder(folder, name: name)
        }
        folderEditor = nil
    }

    private func handleDrop(_ payload: String?, parentId: String?) -> Bool {
        guard let payload else { return false }
        if payload.hasPrefix("server:"),
           let server = inventoryState.servers.first(where: { $0.id == String(payload.dropFirst(7)) }),
           projection.canMoveServer(toFolderId: parentId) {
            appState.moveServer(server, toFolderId: parentId)
            return true
        }
        if payload.hasPrefix("folder:"),
           let folder = appState.serverOrganization.folders.first(where: { $0.id == String(payload.dropFirst(7)) }),
           projection.canMoveFolder(folder.id, toParentId: parentId) {
            appState.moveServerFolder(folder, toParentId: parentId)
            return true
        }
        return false
    }

    private func requestDeletion(_ folder: ServerFolder) {
        if folderHasContent(folder) { populatedDeletion = folder }
        else { emptyDeletion = folder }
    }

    private func folderHasContent(_ folder: ServerFolder) -> Bool {
        let subtree = subtreeIds(of: folder.id)
        return subtree.count > 1 || inventoryState.servers.contains { server in
            server.folder_id.map(subtree.contains) == true
        }
    }

    private func deletionDestinations(for folder: ServerFolder) -> [ServerFolder] {
        let excluded = subtreeIds(of: folder.id)
        return appState.serverOrganization.folders
            .filter { !excluded.contains($0.id) }
            .sorted {
                folderPath($0).localizedCaseInsensitiveCompare(folderPath($1)) == .orderedAscending
            }
    }

    private func subtreeIds(of folderId: String) -> Set<String> {
        var result: Set<String> = [folderId]
        var pending = [folderId]
        while let current = pending.popLast() {
            for child in appState.serverOrganization.folders where child.parent_id == current {
                if result.insert(child.id).inserted { pending.append(child.id) }
            }
        }
        return result
    }

    private func folderPath(_ folder: ServerFolder) -> String {
        projection.path(forFolderId: folder.id) ?? folder.name
    }

    private func title(for view: ServerSystemView) -> String {
        switch view {
        case .all: return "全部服务器"
        case .pinned: return "置顶"
        case .recent: return "最近连接"
        case .uncategorized: return "未分类"
        }
    }

    private func icon(for view: ServerSystemView) -> String {
        switch view {
        case .all: return "rectangle.stack"
        case .pinned: return "pin"
        case .recent: return "clock"
        case .uncategorized: return "tray"
        }
    }
}

private enum FolderEditor {
    case create(parentId: String?)
    case rename(ServerFolder)

    var title: String {
        switch self {
        case .create: return "新建目录"
        case .rename: return "重命名目录"
        }
    }
}
