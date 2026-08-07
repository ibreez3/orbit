import SwiftUI
import AppKit

enum SpotlightItem: Identifiable {
    case snippet(CommandSnippet)
    case action(String, String, () -> Void)

    var id: String {
        switch self {
        case .snippet(let snippet): return "snippet-\(snippet.id)"
        case .action(let title, _, _): return "action-\(title)"
        }
    }
}

struct SpotlightView: View {
    @EnvironmentObject var uiState: UIState
    let appState: AppState
    @FocusState private var isSearchFocused: Bool
    @State private var selectedIndex = 0
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(maxHeight: 520)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: uiState.spotlightQuery) { _ in
            selectedIndex = 0
        }
    }

    private var allItems: [SpotlightItem] {
        filteredSnippets.map(SpotlightItem.snippet) + filteredActions.map {
            SpotlightItem.action($0.title, $0.icon, $0.action)
        }
    }

    private var actions: [(title: String, icon: String, action: () -> Void)] {
        [
            ("添加服务器", "plus.circle", {
                appState.closeSpotlight()
                appState.openDialog()
            }),
            ("添加数据库连接", "cylinder", {
                appState.closeSpotlight()
                appState.openDatabaseConnectionDialog()
            }),
            ("新建凭据组", "key.badge.plus", {
                appState.closeSpotlight()
                appState.openCgDialog()
            }),
            ("打开设置", "gearshape", {
                appState.closeSpotlight()
                SettingsWindowController.shared.open(with: appState)
            }),
            ("切换主题", "circle.lefthalf.filled", {
                let themes = AppTheme.allCases
                if let index = themes.firstIndex(of: appState.theme) {
                    appState.setTheme(themes[(index + 1) % themes.count])
                }
                appState.closeSpotlight()
            })
        ]
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索命令片段或操作…", text: Binding(
                get: { uiState.spotlightQuery },
                set: { uiState.spotlightQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isSearchFocused)
            .accessibilityLabel("搜索命令面板")
            Button(action: { appState.closeSpotlight() }) {
                Text("Esc")
                    .font(.system(size: 11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(minWidth: 28, minHeight: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭命令面板")
            .accessibilityLabel("关闭命令面板")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !filteredSnippets.isEmpty {
                        sectionHeader("命令片段", icon: "text.insert")
                        ForEach(filteredSnippets) { snippet in
                            let index = allItems.firstIndex { item in
                                if case .snippet(let candidate) = item {
                                    return candidate.id == snippet.id
                                }
                                return false
                            }
                            itemRow(
                                title: snippet.name,
                                detail: snippet.command,
                                icon: "terminal",
                                isSelected: index == selectedIndex
                            ) {
                                runSnippet(snippet)
                            }
                            .id(SpotlightItem.snippet(snippet).id)
                        }
                    }

                    sectionHeader("应用操作", icon: "bolt")
                    ForEach(filteredActions, id: \.title) { action in
                        let index = allItems.firstIndex { item in
                            if case .action(let title, _, _) = item {
                                return title == action.title
                            }
                            return false
                        }
                        itemRow(
                            title: action.title,
                            detail: nil,
                            icon: action.icon,
                            isSelected: index == selectedIndex,
                            action: action.action
                        )
                        .id("action-\(action.title)")
                    }
                }
            }
            .onChange(of: selectedIndex) { index in
                guard allItems.indices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(allItems[index].id, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("↑↓ 导航")
            Text("↵ 执行")
            Spacer()
            Text("⌘⇧P 命令面板")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func itemRow(
        title: String,
        detail: String?,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var filteredSnippets: [CommandSnippet] {
        let query = normalizedQuery
        guard !query.isEmpty else { return appState.snippets }
        return appState.snippets.filter { snippet in
            snippet.name.lowercased().contains(query) ||
            snippet.command.lowercased().contains(query) ||
            snippet.description.lowercased().contains(query) ||
            snippet.tags.contains { $0.lowercased().contains(query) }
        }
    }

    private var filteredActions: [(title: String, icon: String, action: () -> Void)] {
        guard !normalizedQuery.isEmpty else { return actions }
        return actions.filter { $0.title.lowercased().contains(normalizedQuery) }
    }

    private var normalizedQuery: String {
        uiState.spotlightQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func runSnippet(_ snippet: CommandSnippet) {
        if let activeId = appState.activeTabId,
           let tab = appState.tabs.first(where: { $0.id == activeId }),
           let sessionId = tab.focusedChannelId ?? tab.sessionId,
           let terminalView = OrbitBridge.shared.terminalView(for: sessionId) as? OrbitTerminalView {
            appState.insertSnippetCommand(snippet.command, into: terminalView)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet.command, forType: .string)
        }
        appState.closeSpotlight()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard uiState.spotlightOpen else { return event }
            switch event.keyCode {
            case 126:
                moveSelection(-1)
                return nil
            case 125:
                moveSelection(1)
                return nil
            case 36:
                confirmSelection()
                return nil
            case 53:
                appState.closeSpotlight()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !allItems.isEmpty else { return }
        selectedIndex = max(0, min(allItems.count - 1, selectedIndex + delta))
    }

    private func confirmSelection() {
        guard allItems.indices.contains(selectedIndex) else { return }
        switch allItems[selectedIndex] {
        case .snippet(let snippet):
            runSnippet(snippet)
        case .action(_, _, let action):
            action()
        }
    }
}
