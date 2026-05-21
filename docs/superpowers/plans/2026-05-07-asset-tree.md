# 资产树 + 页面重构 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 引入左侧常驻资产树导航面板，重构欢迎页为快捷入口 + 最近连接

**Architecture:** 新建 AssetTreeView 替代 SnippetListView（移除），MainView 的 HStack 增加资产树面板。HomeView 重写为欢迎页。AppState 新增宽度和最近连接追踪。

**Tech Stack:** SwiftUI, ObservableObject

**Modify:**
- `orbit-app/Orbit/ViewModels/AppState.swift` — 新增属性
- `orbit-app/Orbit/Views/MainView.swift` — 布局调整
- `orbit-app/Orbit/Views/HomeView.swift` — 重写

**Create:**
- `orbit-app/Orbit/Views/AssetTreeView.swift` — 资产树

**Delete:**
- `orbit-app/Orbit/Views/SnippetListView.swift` — 整合到资产树

---

### Task 1: AppState 新增资产树属性

**Files:**
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`

- [ ] **Step 1: 在 AppState 属性区追加属性**

在现有 `@Published var aiPendingConfirmation` 之后（约第 41 行）追加：

```swift
    @Published var assetTreeWidth: CGFloat = 220
    @Published var recentServers: [String] = []     // 最多 6 个 serverId
    @Published var assetTreeSearchQuery: String = ""
```

- [ ] **Step 2: 追加工具方法和持久化**

在 AppState 末尾追加：

```swift
    // MARK: - Asset Tree & Recent Servers

    func loadAssetTreeWidth() {
        let w = UserDefaults.standard.double(forKey: "assetTreeWidth")
        if w >= 160 && w <= 350 { assetTreeWidth = w }
    }

    func saveAssetTreeWidth(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: "assetTreeWidth")
    }

    func loadRecentServers() {
        guard let data = UserDefaults.standard.data(forKey: "recentServers") else { return }
        do {
            recentServers = try JSONDecoder().decode([String].self, from: data)
        } catch {
            print("[Orbit] Failed to load recent servers: \(error)")
        }
    }

    func saveRecentServers() {
        do {
            let data = try JSONEncoder().encode(recentServers)
            UserDefaults.standard.set(data, forKey: "recentServers")
        } catch {
            print("[Orbit] Failed to save recent servers: \(error)")
        }
    }

    func trackRecentServer(_ serverId: String) {
        recentServers.removeAll { $0 == serverId }
        recentServers.insert(serverId, at: 0)
        if recentServers.count > 6 { recentServers = Array(recentServers.prefix(6)) }
        saveRecentServers()
    }
```

- [ ] **Step 3: 更新 init()**

在 `init()` 中添加加载调用。找到 `loadAIPanelWidth()` 行后追加：

```swift
        loadAssetTreeWidth()
        loadRecentServers()
```

- [ ] **Step 4: 在 addTab 中追踪**

找到 `func addTab(server: TabType:)` 方法，在 `tabs.append(tab)` 之后追加：

```swift
        trackRecentServer(server.id)
```

- [ ] **Step 5: Build 验证**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add orbit-app/Orbit/ViewModels/AppState.swift
git commit -m "feat: add asset tree width, recent servers tracking to AppState"
```

---

### Task 2: 新建 AssetTreeView

**Files:**
- Create: `orbit-app/Orbit/Views/AssetTreeView.swift`

- [ ] **Step 1: 创建完整文件**

```swift
import SwiftUI

struct AssetTreeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("搜索服务器...", text: $appState.assetTreeSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !appState.assetTreeSearchQuery.isEmpty {
                    Button(action: { appState.assetTreeSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Tree content
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    if appState.assetTreeSearchQuery.isEmpty {
                        serverGroupsSection
                        credentialsSection
                        snippetsSection
                    } else {
                        searchResults
                    }
                }
                .padding(.bottom, 28)
            }

            Divider()

            // Bottom toolbar
            HStack {
                Button(action: { appState.openDialog() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("添加服务器")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 160)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Server Groups

    private var serverGroupsSection: some View {
        let groups = Dictionary(grouping: appState.servers) {
            $0.group_name.isEmpty ? "服务器" : $0.group_name
        }
        let sorted = groups.sorted { $0.key < $1.key }

        return ForEach(sorted, id: \.key) { groupName, servers in
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedGroups.contains(groupName) },
                    set: { isExpanded in
                        if isExpanded { expandedGroups.insert(groupName) }
                        else { expandedGroups.remove(groupName) }
                    }
                ),
                content: {
                    ForEach(servers) { server in
                        ServerNodeRow(server: server)
                    }
                },
                label: {
                    HStack {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                        Text(groupName)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(servers.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            )
        }
        .padding(.vertical, 2)
    }

    @State private var expandedGroups: Set<String> = []

    // MARK: - Credentials Section

    private var credentialsSection: some View {
        let filtered = appState.credentialGroups
        guard !filtered.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            DisclosureGroup(
                isExpanded: $credentialsExpanded,
                content: {
                    ForEach(filtered) { cg in
                        HStack {
                            Image(systemName: "key")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow)
                            Text(cg.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            appState.openCgDialog(cg)
                        }
                    }
                },
                label: {
                    HStack {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 11))
                            .foregroundStyle(.gray)
                        Text("凭据组")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            )
        )
    }

    @State private var credentialsExpanded: Bool = false

    // MARK: - Snippets Section

    private var snippetsSection: some View {
        let filtered = appState.snippets
        guard !filtered.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            DisclosureGroup(
                isExpanded: $snippetsExpanded,
                content: {
                    ForEach(filtered) { snippet in
                        HStack {
                            Image(systemName: "terminal")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                            Text(snippet.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                            Text(snippet.command)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let activeId = appState.activeTabId,
                               let tab = appState.tabs.first(where: { $0.id == activeId }),
                               let sid = tab.sessionId ?? tab.focusedChannelId,
                               let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView {
                                appState.insertSnippetCommand(snippet.command, into: tv)
                            } else {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(snippet.command, forType: .string)
                            }
                        }
                    }
                },
                label: {
                    HStack {
                        Image(systemName: "text.insert")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        Text("命令片段")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(filtered.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            )
        )
    }

    @State private var snippetsExpanded: Bool = false

    // MARK: - Search Results

    private var searchResults: some View {
        let q = appState.assetTreeSearchQuery.lowercased()
        let matched = appState.servers.filter {
            $0.name.lowercased().contains(q) || $0.host.lowercased().contains(q)
        }
        return ForEach(matched) { server in
            ServerNodeRow(server: server)
        }
    }
}

// MARK: - Server Node Row

private struct ServerNodeRow: View {
    let server: Server
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.tabs.contains(where: { $0.serverId == server.id }) ? Color.green : Color.gray)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text("\(server.host):\(server.port)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.addTab(server: server, type: .terminal)
            appState.trackRecentServer(server.id)
        }
        .contextMenu {
            Button("SSH 终端") { appState.addTab(server: server, type: .terminal) }
            Button("SFTP") { appState.addTab(server: server, type: .sftp) }
            Button("监控") { appState.addTab(server: server, type: .monitor) }
            Divider()
            Button("编辑") { appState.openDialog(server: server) }
            Button("删除", role: .destructive) { appState.deleteServer(server.id) }
        }
    }
}
```

- [ ] **Step 2: 在 project.yml 新增文件引用**

编辑 `orbit-app/project.yml`，在 `sources` 数组中追加：

```yaml
          - Orbit/Views/AssetTreeView.swift
```

- [ ] **Step 3: 生成 Xcode 工程**

```bash
cd orbit-app && xcodegen generate
```

- [ ] **Step 4: Build 验证**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add orbit-app/Orbit/Views/AssetTreeView.swift orbit-app/project.yml
git commit -m "feat: add AssetTreeView with server groups, credentials, snippets"
```

---

### Task 3: 重写 HomeView 为欢迎页

**Files:**
- Modify: `orbit-app/Orbit/Views/HomeView.swift`

- [ ] **Step 1: 完全替换 HomeView.swift**

```swift
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
```

- [ ] **Step 2: Build 验证**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add orbit-app/Orbit/Views/HomeView.swift
git commit -m "feat: rewrite HomeView as welcome page with quick actions and recent servers"
```

---

### Task 4: MainView 重构 — 集成资产树

**Files:**
- Modify: `orbit-app/Orbit/Views/MainView.swift`
- Delete: `orbit-app/Orbit/Views/SnippetListView.swift`

- [ ] **Step 1: 修改 MainView — 资产树替代 snippet 面板**

替换 `mainLayout` computed property（第 68-95 行）为：

```swift
    private var mainLayout: some View {
        HStack(spacing: 0) {
            // Asset tree (left, always visible)
            AssetTreeView()
                .environmentObject(appState)
                .frame(width: appState.assetTreeWidth)

            // Resize handle
            Rectangle()
                .fill(Color.primary.opacity(0.0))
                .frame(width: 5)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newWidth = appState.assetTreeWidth + value.translation.width
                            appState.assetTreeWidth = min(350, max(160, newWidth))
                        }
                        .onEnded { _ in
                            appState.saveAssetTreeWidth(appState.assetTreeWidth)
                        }
                )

            Divider()

            // Main content
            VStack(spacing: 0) {
                TabBarView()
                contentArea
                sftpDrawer
                StatusBarView()
            }

            // AI panel (right)
            if appState.aiPanelOpen {
                Divider()
                AIChatView()
                    .environmentObject(appState)
            }
        }
        .background(themeWindowColor)
        .preferredColorScheme(themeColorScheme)
    }
```

- [ ] **Step 2: 移除 snippetPanelVisible 相关代码**

删除 `@State private var snippetPanelVisible: Bool = false` 声明（第 5 行附近）。

删除 `.onReceive(nc(.openSnippetPicker))` 那行（第 59 行）。

在 `project.yml` 中移除 `Orbit/Views/SnippetListView.swift` 引用。

- [ ] **Step 3: 删除 SnippetListView.swift**

```bash
rm orbit-app/Orbit/Views/SnippetListView.swift
```

- [ ] **Step 4: 更新 project.yml 并重新生成工程**

从 project.yml 的 sources 中移除 SnippetListView，然后：

```bash
cd orbit-app && xcodegen generate
```

- [ ] **Step 5: Build 验证**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add orbit-app/Orbit/Views/MainView.swift orbit-app/Orbit/Views/SnippetListView.swift orbit-app/project.yml
git commit -m "feat: integrate AssetTreeView into MainView, remove SnippetListView"
```

---

### Task 5: 最终验证

- [ ] **Step 1: 完整构建**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: 确认无编译警告**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | grep -i "warning" | grep -v "SDK"
```

Expected: 无新增警告（或仅有 SDK version warning）

- [ ] **Step 3: Commit**

```bash
git commit --allow-empty -m "chore: final verification — asset tree and welcome page complete"
```
