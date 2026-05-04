import SwiftUI

struct SnippetListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""
    @State private var filterTag: String? = nil

    var filteredSnippets: [CommandSnippet] {
        var result = appState.snippets
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q) ||
                $0.command.lowercased().contains(q) ||
                $0.description.lowercased().contains(q) ||
                $0.tags.contains(where: { $0.lowercased().contains(q) })
            }
        }
        if let tag = filterTag {
            result = result.filter { $0.tags.contains(tag) }
        }
        return result
    }

    var allTags: [String] {
        Array(Set(appState.snippets.flatMap { $0.tags })).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("命令片段")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { appState.openSnippetEditor() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("新建片段")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("搜索片段...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            // Tag filter
            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        TagPill(text: "全部", isActive: filterTag == nil) {
                            filterTag = nil
                        }
                        ForEach(allTags, id: \.self) { tag in
                            TagPill(text: tag, isActive: filterTag == tag) {
                                filterTag = filterTag == tag ? nil : tag
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 6)
            }

            // Snippet list
            if filteredSnippets.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredSnippets) { snippet in
                            SnippetRow(snippet: snippet)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(minWidth: 220)
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $appState.snippetEditorOpen) {
            SnippetEditorView()
                .environmentObject(appState)
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.insert")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("暂无命令片段")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("点击 + 创建你的第一个片段")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private struct TagPill: View {
    let text: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 10))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Color.accentColor : Color.primary.opacity(0.08))
                .foregroundStyle(isActive ? .white : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SnippetRow: View {
    let snippet: CommandSnippet
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(snippet.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 2) {
                Button(action: {
                    if let activeId = appState.activeTabId,
                       let tab = appState.tabs.first(where: { $0.id == activeId }),
                       let sid = tab.sessionId ?? tab.focusedChannelId,
                       let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView {
                        appState.insertSnippetCommand(snippet.command, into: tv)
                    }
                }) {
                    Image(systemName: "arrow.forward.circle")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("插入到终端")

                Button(action: { appState.openSnippetEditor(snippet: snippet) }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("插入到终端") {
                if let activeId = appState.activeTabId,
                   let tab = appState.tabs.first(where: { $0.id == activeId }),
                   let sid = tab.sessionId ?? tab.focusedChannelId,
                   let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView {
                    appState.insertSnippetCommand(snippet.command, into: tv)
                }
            }
            Button("编辑") { appState.openSnippetEditor(snippet: snippet) }
            Divider()
            Button("删除") { appState.deleteSnippet(snippet.id) }
        }
    }
}
