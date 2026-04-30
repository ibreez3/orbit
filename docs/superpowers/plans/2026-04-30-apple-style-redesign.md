# Orbit Apple-Style UI Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sidebar-based layout with a Spotlight-driven, terminal-first Apple-style UI.

**Architecture:** Remove SidebarView, add SpotlightView (⌘K popup), convert SFTP from tab to bottom drawer, add Database tab (3-panel), add Settings tab, add theme system (Light/Dark/Catppuccin Mocha). MainView becomes: TabBar → Content → SftpDrawer → StatusBar with Spotlight as overlay.

**Tech Stack:** SwiftUI + AppKit (existing), SwiftTerm (terminal), Swift Charts (monitoring). No Rust changes needed.

**Spec:** `docs/2026-04-30-apple-style-redesign-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Models.swift` | Modify | Add `AppTheme` enum, `TabType.database`, `SpotlightSection` |
| `AppState.swift` | Modify | Add spotlight, drawer, theme state; remove sidebar state |
| `OrbitApp.swift` | Modify | Add ⌘K shortcut for Spotlight |
| `MainView.swift` | Modify | Full restructure: remove sidebar, add overlay + drawer layout |
| `Views/SpotlightView.swift` | Create | Spotlight popup (⌘K) |
| `Views/TabBarView.swift` | Create | Safari-style tab bar with status dots |
| `Views/StatusBarView.swift` | Create | Frosted glass mini status bar |
| `Views/SftpDrawerView.swift` | Create | Bottom drawer SFTP (wraps existing SftpView logic) |
| `Views/DatabaseView.swift` | Create | 3-panel database tab |
| `Views/SettingsView.swift` | Create | Settings tab with theme cards + terminal config |
| `Views/SidebarView.swift` | Delete | Replaced by Spotlight |
| `Views/MonitorView.swift` | Keep | Unchanged for now (not in redesign scope) |
| `Views/SftpView.swift` | Keep | Its logic reused by SftpDrawerView |

---

### Task 1: Update Models

**Files:**
- Modify: `orbit-app/Orbit/Models/Models.swift`

- [ ] **Step 1: Add AppTheme enum and update TabType**

Add to `Models.swift` after the existing `TabType` enum:

```swift
enum AppTheme: String, CaseIterable {
    case light
    case dark
    case catppuccinMocha
}

enum SpotlightSection: String, CaseIterable {
    case servers
    case databases
    case credentials
    case actions
}
```

Update the existing `TabType` enum to add the `database` and `settings` cases:

```swift
enum TabType: String, CaseIterable {
    case terminal
    case sftp
    case monitor
    case database
    case settings
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/sunyang/workspace/orbit/orbit/orbit-app && xcodegen generate && cd .. && xcodebuild -project orbit-app/Orbit.xcodeproj -scheme Orbit -configuration Debug build 2>&1 | tail -5`

Expected: Build may fail on unused TabType cases in switch statements — that's expected, we'll fix in later tasks.

---

### Task 2: Update AppState

**Files:**
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`

- [ ] **Step 1: Add spotlight, drawer, theme state**

Add new `@Published` properties to `AppState`:

```swift
@Published var spotlightOpen: Bool = false
@Published var spotlightQuery: String = ""
@Published var sftpDrawerTabId: String? = nil
@Published var sftpDrawerHeight: CGFloat = 280
@Published var theme: AppTheme = .catppuccinMocha
```

Add methods:

```swift
func openSpotlight() {
    spotlightQuery = ""
    spotlightOpen = true
}

func closeSpotlight() {
    spotlightOpen = false
    spotlightQuery = ""
}

func toggleSftpDrawer(for tabId: String) {
    if sftpDrawerTabId == tabId {
        sftpDrawerTabId = nil
    } else {
        sftpDrawerTabId = tabId
    }
}

func setTheme(_ newTheme: AppTheme) {
    theme = newTheme
}
```

Remove `@Published var sidebarCollapsed: Bool = false` and the `toggleSidebar()` method since the sidebar is being removed.

- [ ] **Step 2: Build to verify**

Expected: May have compile errors from removed `sidebarCollapsed` references in MainView — will fix in Task 9.

---

### Task 3: Create TabBarView

**Files:**
- Create: `orbit-app/Orbit/Views/TabBarView.swift`

- [ ] **Step 1: Write TabBarView**

```swift
import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(appState.tabs) { tab in
                        tabPill(tab)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()

            Button(action: { appState.openSpotlight() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Spotlight (⌘K)")

            Button(action: {}) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
            }
            .buttonStyle(.plain)
            .help("Network status")

            Button(action: { appState.addTab(server: Server.placeholder, type: .settings) }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func tabPill(_ tab: TabItem) -> some View {
        let isActive = tab.id == appState.activeTabId
        return HStack(spacing: 5) {
            Circle()
                .fill(connectionColor(tab))
                .frame(width: 6, height: 6)
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
            if isActive {
                Button(action: { closeTab(tab) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isActive ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture { appState.activeTabId = tab.id }
        .onTapGesture(count: 2) {
            if tab.type == .terminal {
                appState.toggleSftpDrawer(for: tab.id)
            }
        }
    }

    private func connectionColor(_ tab: TabItem) -> Color {
        if tab.sessionId != nil { return .green }
        return .secondary
    }

    private func closeTab(_ tab: TabItem) {
        if tab.type == .terminal, tab.sessionId != nil {
            let alert = NSAlert()
            alert.messageText = "确定关闭终端 \"\(tab.title)\" 吗？"
            alert.informativeText = "连接将被断开。"
            alert.addButton(withTitle: "关闭")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            guard let window = NSApp.keyWindow else {
                appState.removeTab(tab.id)
                return
            }
            alert.beginSheetModal(for: window) { resp in
                if resp == .alertFirstButtonReturn {
                    appState.removeTab(tab.id)
                }
            }
        } else {
            appState.removeTab(tab.id)
        }
    }
}
```

Add a placeholder extension to `Server` in Models.swift for the settings tab:

```swift
extension Server {
    static let placeholder = Server(
        id: "", name: "", host: "", port: 0, group_name: "",
        auth_type: "", username: "", password: "", private_key: "",
        key_source: "", key_file_path: "", key_passphrase: "",
        credential_group_id: "", jump_server_id: "",
        created_at: "", updated_at: ""
    )
}
```

- [ ] **Step 2: Build to verify**

---

### Task 4: Create StatusBarView

**Files:**
- Create: `orbit-app/Orbit/Views/StatusBarView.swift`

- [ ] **Step 1: Write StatusBarView**

```swift
import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            if let activeTab = activeTab {
                Text(activeTab.serverName)
                    .lineLimit(1)
                if activeTab.type == .database {
                    Text("· 只读")
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("无连接")
            }

            Spacer()

            Text("⌘K 搜索")
            Text("⌘, 设置")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private var activeTab: TabItem? {
        appState.tabs.first(where: { $0.id == appState.activeTabId })
    }

    private var statusColor: Color {
        guard let tab = activeTab else { return .secondary }
        if tab.type == .terminal || tab.type == .sftp {
            return tab.sessionId != nil ? .green : .secondary
        }
        return .green
    }
}
```

- [ ] **Step 2: Build to verify**

---

### Task 5: Create SpotlightView

**Files:**
- Create: `orbit-app/Orbit/Views/SpotlightView.swift`

- [ ] **Step 1: Write SpotlightView**

```swift
import SwiftUI

struct SpotlightView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isSearchFocused: Bool
    @State private var selectedSection: SpotlightSection = .servers

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
        .onAppear { isSearchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField("搜索服务器、数据库、凭证、命令…", text: $appState.spotlightQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isSearchFocused)
            Button(action: { appState.closeSpotlight() }) {
                Text("Esc")
                    .font(.system(size: 11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                serversSection
                if appState.credentialGroups.isEmpty == false {
                    credentialsSection
                }
                quickActionsSection
            }
        }
    }

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("服务器", icon: "server.rack")
            let groups = Dictionary(grouping: filteredServers) { $0.group_name.isEmpty ? "默认" : $0.group_name }
            ForEach(groups.keys.sorted(), id: \.self) { groupName in
                if let servers = groups[groupName] {
                    groupRow(name: groupName, count: servers.count)
                    ForEach(servers) { server in
                        serverRow(server)
                    }
                }
            }
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("凭证", icon: "key.round")
            ForEach(filteredCredentials) { cg in
                credentialRow(cg)
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("快捷操作", icon: "bolt")
            actionRow("添加服务器", icon: "plus.circle") {
                appState.closeSpotlight()
                appState.openDialog()
            }
            actionRow("添加数据库连接", icon: "cylinder") {
                appState.closeSpotlight()
                toast("添加数据库连接（待实现）")
            }
            actionRow("新建凭证", icon: "key.badge.plus") {
                appState.closeSpotlight()
                appState.openCgDialog()
            }
            actionRow("切换主题", icon: "circle.lefthalf.filled") {
                appState.closeSpotlight()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("↑↓ 导航")
            Text("↵ 确认")
            Text("⌘N 新建服务器")
            Spacer()
            Text("双击 → SSH")
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
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func groupRow(name: String, count: Int) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .foregroundStyle(.secondary)
    }

    private func serverRow(_ server: Server) -> some View {
        HStack(spacing: 8) {
            Image(systemName: server.isJumpConfigured ? "arrow.triangle.branch" : "server.rack")
                .foregroundStyle(server.isJumpConfigured ? .cyan : .green)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(server.name)
                .font(.system(size: 13))
            Text(server.host)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: {
                appState.addTab(server: server, type: .sftp)
                appState.closeSpotlight()
            }) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("打开 SFTP")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.addTab(server: server, type: .terminal)
            appState.closeSpotlight()
        }
    }

    private func credentialRow(_ cg: CredentialGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.round")
                .foregroundStyle(.purple)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(cg.name)
                .font(.system(size: 13))
            Text(cg.auth_type)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.openCgDialog(cg)
            appState.closeSpotlight()
        }
    }

    private func actionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredServers: [Server] {
        let q = appState.spotlightQuery.lowercased()
        if q.isEmpty { return appState.servers }
        return appState.servers.filter {
            $0.name.lowercased().contains(q) ||
            $0.host.lowercased().contains(q) ||
            $0.group_name.lowercased().contains(q)
        }
    }

    private var filteredCredentials: [CredentialGroup] {
        let q = appState.spotlightQuery.lowercased()
        if q.isEmpty { return appState.credentialGroups }
        return appState.credentialGroups.filter {
            $0.name.lowercased().contains(q)
        }
    }

    private func toast(_ msg: String) {
        print("[Spotlight] \(msg)")
    }
}
```

- [ ] **Step 2: Build to verify**

---

### Task 6: Create SftpDrawerView

**Files:**
- Create: `orbit-app/Orbit/Views/SftpDrawerView.swift`

- [ ] **Step 1: Write SftpDrawerView**

This wraps the existing SftpView as a bottom drawer:

```swift
import SwiftUI

struct SftpDrawerView: View {
    let tab: TabItem
    @EnvironmentObject var appState: AppState
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            SftpView(tab: tab)
        }
        .frame(height: appState.sftpDrawerHeight)
        .background(.ultraThinMaterial)
    }

    private var dragHandle: some View {
        VStack(spacing: 4) {
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 4)

            HStack {
                Text("SFTP · \(tab.serverName)")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(action: { appState.sftpDrawerTabId = nil }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let newHeight = appState.sftpDrawerHeight - value.translation.height
                    appState.sftpDrawerHeight = max(160, min(newHeight, 600))
                }
        )
    }
}
```

- [ ] **Step 2: Build to verify**

---

### Task 7: Create DatabaseView

**Files:**
- Create: `orbit-app/Orbit/Views/DatabaseView.swift`

- [ ] **Step 1: Write DatabaseView (3-panel layout)**

This is a stub UI. The actual DB FFI calls are not yet implemented in Rust.

```swift
import SwiftUI

struct DatabaseView: View {
    let tab: TabItem
    @State private var selectedTable: String? = nil
    @State private var sqlText: String = "SELECT * FROM orders LIMIT 100;"
    @State private var tableSearchQuery: String = ""

    var body: some View {
        HSplitView {
            tableListPanel
            editorAndResultsPanel
        }
    }

    private var tableListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索表…", text: $tableSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(8)
            .background(.ultraThinMaterial)

            Divider()

            List(selection: $selectedTable) {
                ForEach(mockTables, id: \.self) { table in
                    HStack {
                        Image(systemName: "tablecells")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(table)
                            .font(.system(size: 12))
                    }
                    .tag(table)
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
    }

    private var editorAndResultsPanel: some View {
        VStack(spacing: 0) {
            sqlEditor
            Divider()
            resultsPanel
        }
    }

    private var sqlEditor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $sqlText)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("格式化") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(action: {}) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("执行")
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .frame(minHeight: 120)
    }

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            if selectedTable != nil {
                Table(mockResults) {
                    TableColumn("status") { row in Text(row.status) }
                    TableColumn("cnt") { row in Text("\(row.cnt)").frame(maxWidth: .infinity, alignment: .trailing) }
                }
                .tableStyle(.inset)
            } else {
                Text("执行 SQL 查看结果")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text("数据库面板（待接入后端）")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("⌘Enter 执行")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
        }
    }

    private var mockTables: [String] {
        let all = ["orders", "users", "products", "payments", "sessions"]
        let q = tableSearchQuery.lowercased()
        if q.isEmpty { return all }
        return all.filter { $0.contains(q) }
    }
}

private struct MockResult: Identifiable {
    let id = UUID()
    let status: String
    let cnt: Int
}

private let mockResults = [
    MockResult(status: "PAID", cnt: 12042),
    MockResult(status: "PENDING", cnt: 642),
    MockResult(status: "FAILED", cnt: 39),
]
```

- [ ] **Step 2: Build to verify**

---

### Task 8: Create SettingsView

**Files:**
- Create: `orbit-app/Orbit/Views/SettingsView.swift`

- [ ] **Step 1: Write SettingsView**

```swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("fontSize") private var fontSize: Double = 14
    @AppStorage("lineHeight") private var lineHeight: Double = 1.55
    @AppStorage("cursorStyle") private var cursorStyle: String = "bar"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                appearanceSection
                terminalSection
                connectionSection
            }
            .padding(24)
            .frame(maxWidth: 600)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("外观")

            HStack(spacing: 12) {
                themeCard(.light, name: "Light", colors: [Color.white, Color(red: 0.96, green: 0.96, blue: 0.97)])
                themeCard(.dark, name: "Dark", colors: [Color(red: 0.11, green: 0.11, blue: 0.12), Color.black])
                themeCard(.catppuccinMocha, name: "Catppuccin Mocha", colors: [Color(red: 0.12, green: 0.12, blue: 0.18), Color(red: 0.07, green: 0.07, blue: 0.11)])
            }
        }
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("终端")

            HStack {
                Text("字体大小")
                Spacer()
                Text("\(Int(fontSize))px")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $fontSize, in: 12...20, step: 1)

            HStack {
                Text("行高")
                Spacer()
                Text(String(format: "%.2f", lineHeight))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $lineHeight, in: 1.2...1.8, step: 0.05)

            HStack {
                Text("光标样式")
                Spacer()
                Picker("", selection: $cursorStyle) {
                    Text("竖线").tag("bar")
                    Text("方块").tag("block")
                    Text("下划线").tag("underline")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("连接")
            HStack {
                Text("默认超时")
                Spacer()
                Text("10s")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("重连策略")
                Spacer()
                Text("自动重连")
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
    }

    private func themeCard(_ theme: AppTheme, name: String, colors: [Color]) -> some View {
        let isSelected = appState.theme == theme
        return Button(action: { appState.setTheme(theme) }) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                        )
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(.white).padding(-2))
                    }
                }
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build to verify**

---

### Task 9: Restructure MainView

**Files:**
- Modify: `orbit-app/Orbit/Views/MainView.swift`

- [ ] **Step 1: Rewrite MainView**

Replace the entire body of `MainView` with the new layout:

```swift
import SwiftUI

struct MainView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        ZStack {
            mainLayout
            spotlightOverlay
        }
        .frame(minWidth: 900, minHeight: 600)
        .environmentObject(appState)
        .sheet(isPresented: Binding(
            get: { appState.dialogOpen },
            set: { if !$0 { appState.closeDialog() } }
        )) {
            ServerDialog()
                .environmentObject(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.cgDialogOpen },
            set: { if !$0 { appState.closeCgDialog() } }
        )) {
            CredentialGroupDialog()
                .environmentObject(appState)
        }
        .onAppear {
            appState.loadServers()
            appState.loadCredentialGroups()
            if appState.servers.isEmpty {
                appState.openSpotlight()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTerminal)) { _ in
            appState.openSpotlight()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSpotlight)) { _ in
            appState.openSpotlight()
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitHorizontal)) { _ in
            appState.splitCurrentPane(direction: .horizontal)
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitVertical)) { _ in
            appState.splitCurrentPane(direction: .vertical)
        }
        .onReceive(NotificationCenter.default.publisher(for: .closePane)) { _ in
            appState.closeCurrentPane()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigatePrevPane)) { _ in
            appState.navigatePane(forward: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateNextPane)) { _ in
            appState.navigatePane(forward: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateLeftPane)) { _ in
            appState.navigatePane(forward: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateRightPane)) { _ in
            appState.navigatePane(forward: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .growPane)) { _ in
            appState.resizePane(grow: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shrinkPane)) { _ in
            appState.resizePane(grow: false)
        }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            TabBarView()
            contentArea
            sftpDrawer
            StatusBarView()
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if let activeTab = appState.tabs.first(where: { $0.id == appState.activeTabId }) {
            if let tree = activeTab.paneTree {
                SplitPaneView(node: tree, serverId: activeTab.serverId, tabId: activeTab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabContent(activeTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: TabItem) -> some View {
        switch tab.type {
        case .terminal:
            TerminalView(channelId: tab.sessionId, serverId: tab.serverId, tabId: tab.id)
        case .sftp:
            SftpView(tab: tab)
        case .monitor:
            MonitorView(tab: tab)
        case .database:
            DatabaseView(tab: tab)
        case .settings:
            SettingsView()
        }
    }

    @ViewBuilder
    private var sftpDrawer: some View {
        if let drawerTabId = appState.sftpDrawerTabId,
           let tab = appState.tabs.first(where: { $0.id == drawerTabId }) {
            SftpDrawerView(tab: tab)
        }
    }

    private var emptyState: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var spotlightOverlay: some View {
        if appState.spotlightOpen {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { appState.closeSpotlight() }

                SpotlightView()
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

---

### Task 10: Update OrbitApp.swift (Shortcuts)

**Files:**
- Modify: `orbit-app/Orbit/OrbitApp.swift`

- [ ] **Step 1: Add ⌘K and ⌘, shortcuts**

Add to `OrbitCommands` body, before the existing `CommandGroup(replacing: .newItem)`:

```swift
CommandGroup(after: .toolbar) {
    Button("Spotlight") {
        NotificationCenter.default.post(name: .openSpotlight, object: nil)
    }
    .keyboardShortcut("k", modifiers: .command)
}
```

Add to `Notification.Name` extension:

```swift
static let openSpotlight = Notification.Name("openSpotlight")
```

- [ ] **Step 2: Build to verify**

---

### Task 11: Regenerate Xcode Project & Final Build

**Files:**
- Modify: `orbit-app/Orbit.xcodeproj` (regenerated)

- [ ] **Step 1: Run xcodegen**

Run: `cd /Users/sunyang/workspace/orbit/orbit/orbit-app && xcodegen generate`

- [ ] **Step 2: Full build**

Run: `cd /Users/sunyang/workspace/orbit/orbit && xcodebuild -project orbit-app/Orbit.xcodeproj -scheme Orbit -configuration Debug build 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit all changes**

```bash
cd /Users/sunyang/workspace/orbit/orbit
git add -A
git commit -m "feat: apple-style UI redesign — spotlight, sftp drawer, db panel, themes"
```
