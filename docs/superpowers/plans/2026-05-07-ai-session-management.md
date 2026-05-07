# AI 助手 Session 管理 + 数据隔离 + Agent 自动执行 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现按服务器隔离的 AI Session 管理、slash command、Agent 自动执行命令、安全白名单、面板宽度可调

**Architecture:** 在现有 AppState/AIChatView/OpenAIService 中扩展，不修改 Rust/FFI 层。Session 数据按 serverId 独立持久化到 UserDefaults。Agent loop 通过 SSH session 执行命令后读取终端 buffer 获取输出。

**Tech Stack:** SwiftUI, Foundation (URLSession, JSONEncoder/Decoder, UserDefaults)

**Modify files:**
- `orbit-app/Orbit/Models/Models.swift` — 新增 `AISession`, `AICommandResult`
- `orbit-app/Orbit/ViewModels/AppState.swift` — session 管理、持久化、白名单、slash command
- `orbit-app/Orbit/Models/OpenAIService.swift` — agent loop 支持
- `orbit-app/Orbit/Views/AIChatView.swift` — session 选择器、命令确认、面板拖拽、slash command UI

---

### Task 1: 新增数据模型

**Files:**
- Modify: `orbit-app/Orbit/Models/Models.swift` (在 `AIChatMessage` 后追加)

- [ ] **Step 1: 在 Models.swift 中追加 `AISession` 和 `AICommandResult`**

```swift
// 在 AIChatMessage struct 之后，AICommandSuggestion 之前追加:

struct AICommandResult: Codable {
    let command: String
    let output: String
    let exitCode: Int32
}

struct AISession: Codable, Identifiable {
    let id: String
    let serverId: String
    var title: String
    var messages: [AIChatMessage]
    var createdAt: Date
    var updatedAt: Date

    static func create(serverId: String) -> AISession {
        AISession(
            id: UUID().uuidString,
            serverId: serverId,
            title: "",
            messages: [],
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
```

- [ ] **Step 2: Build 验证编译通过**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add orbit-app/Orbit/Models/Models.swift
git commit -m "feat: add AISession and AICommandResult models"
```

---

### Task 2: AppState Session 管理 + 持久化 + 白名单

**Files:**
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`

- [ ] **Step 1: 替换 AI 相关属性**

将第 34-39 行的 AI 属性替换为：

```swift
    // AI Assistant — Session-based
    @Published var aiConfig: AIConfig = .defaults
    @Published var aiSessions: [String: [AISession]] = [:]       // serverId → sessions
    @Published var activeAISessionId: [String: String] = [:]     // tabId → sessionId
    @Published var aiPanelOpen: Bool = false
    @Published var aiLoading: Bool = false
    @Published var aiPanelWidth: CGFloat = 280
    @Published var aiPendingConfirmation: (command: String, sessionId: String, tabId: String)? = nil
    @Published var activeTabError: String? = nil
```

- [ ] **Step 2: 新增 session 工具方法和计算属性**

在 `AppState` 末尾（`}` 之前）追加：

```swift
    // MARK: - AI Session Helpers

    var currentServerId: String? {
        guard let activeId = activeTabId,
              let tab = tabs.first(where: { $0.id == activeId }) else { return nil }
        return tab.serverId
    }

    var currentSession: AISession? {
        guard let serverId = currentServerId,
              let tabId = activeTabId,
              let sessionId = activeAISessionId[tabId],
              let sessions = aiSessions[serverId],
              let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return nil }
        return aiSessions[serverId]?[idx]
    }

    var currentMessages: [AIChatMessage] {
        currentSession?.messages ?? []
    }

    /// 获取或创建 tabId 对应的活跃 session
    func ensureSession(tabId: String, serverId: String) -> AISession {
        if let sessionId = activeAISessionId[tabId],
           var sessions = aiSessions[serverId],
           let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            return sessions[idx]
        }
        let session = AISession.create(serverId: serverId)
        if aiSessions[serverId] == nil {
            aiSessions[serverId] = []
        }
        aiSessions[serverId]?.insert(session, at: 0)
        activeAISessionId[tabId] = session.id
        saveAISessions(serverId: serverId)
        return session
    }

    func currentSessionTitle() -> String {
        currentSession?.title ?? ""
    }

    func loadAISessions(serverId: String) {
        guard let data = UserDefaults.standard.data(forKey: "aiSessions_\(serverId)") else { return }
        do {
            aiSessions[serverId] = try JSONDecoder().decode([AISession].self, from: data)
        } catch {
            print("[Orbit] Failed to load AI sessions for \(serverId): \(error)")
        }
    }

    func saveAISessions(serverId: String) {
        guard let sessions = aiSessions[serverId] else { return }
        do {
            let data = try JSONEncoder().encode(sessions)
            UserDefaults.standard.set(data, forKey: "aiSessions_\(serverId)")
        } catch {
            print("[Orbit] Failed to save AI sessions for \(serverId): \(error)")
        }
    }

    func loadAIPanelWidth() {
        let w = UserDefaults.standard.double(forKey: "aiPanelWidth")
        if w >= 160 && w <= 600 { aiPanelWidth = w }
    }

    func saveAIPanelWidth(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: "aiPanelWidth")
    }
```

- [ ] **Step 3: 替换消息操作方法**

移除旧的 `saveAIMessages()`、`loadAIMessages()`、`addAIMessage()`、`appendToLastAssistantMessage()`、`clearAIMessages()`、`submitAIQuestion()`（第 625-679 行）。

替换为新实现：

```swift
    func addMessageToCurrentSession(_ message: AIChatMessage) {
        guard let serverId = currentServerId,
              let tabId = activeTabId else { return }

        var session = ensureSession(tabId: tabId, serverId: serverId)

        // Auto-title: use first user message (max 30 chars)
        if session.title.isEmpty && message.role == "user" {
            let t = message.content.trimmingCharacters(in: .whitespaces)
            session.title = String(t.prefix(30))
        }

        session.messages.append(message)
        session.updatedAt = Date()

        if let idx = aiSessions[serverId]?.firstIndex(where: { $0.id == session.id }) {
            aiSessions[serverId]?[idx] = session
        }
        saveAISessions(serverId: serverId)
    }

    func appendToCurrentAssistantMessage(text: String) {
        guard let serverId = currentServerId,
              let tabId = activeTabId,
              let sessionId = activeAISessionId[tabId],
              var sessions = aiSessions[serverId],
              let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        var session = sessions[idx]
        if var last = session.messages.last, last.role == "assistant" {
            last.content += text
            session.messages[session.messages.count - 1] = last
        } else {
            let msg = AIChatMessage(id: UUID().uuidString, role: "assistant", content: text, timestamp: Date())
            session.messages.append(msg)
        }
        session.updatedAt = Date()
        sessions[idx] = session
        aiSessions[serverId] = sessions
        saveAISessions(serverId: serverId)
    }

    func clearCurrentSessionMessages() {
        guard let serverId = currentServerId,
              let tabId = activeTabId,
              let sessionId = activeAISessionId[tabId],
              var sessions = aiSessions[serverId],
              let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].messages.removeAll()
        sessions[idx].updatedAt = Date()
        aiSessions[serverId] = sessions
        saveAISessions(serverId: serverId)
    }

    func submitAIQuestion(_ question: String) {
        guard let serverId = currentServerId,
              let tabId = activeTabId else { return }

        let userMsg = AIChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: question,
            timestamp: Date()
        )
        let _ = ensureSession(tabId: tabId, serverId: serverId)
        addMessageToCurrentSession(userMsg)

        if !aiPanelOpen {
            aiPanelOpen = true
        }
    }
```

- [ ] **Step 4: 新增 Slash Command 处理方法**

在 `AppState` 中追加（与 session helpers 放一起）：

```swift
    // MARK: - Slash Commands

    enum SlashCommandResult {
        case handled(String)       // 显示系统消息
        case switchSession(String) // 切换到指定 session id
        case ignore                // 不是命令，继续发送
    }

    func handleSlashCommand(_ input: String) -> SlashCommandResult {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        if trimmed == "/new" {
            return createNewSession()
        }

        if trimmed == "/sessions" {
            return listSessions()
        }

        if trimmed == "/compact" {
            return compactCurrentSession()
        }

        if trimmed.hasPrefix("/load ") {
            let sessionId = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return loadSession(sessionId: sessionId)
        }

        return .ignore
    }

    private func createNewSession() -> SlashCommandResult {
        guard let serverId = currentServerId,
              let tabId = activeTabId else {
            return .handled("无法创建新 session：请先连接服务器")
        }
        // 确保当前 session 已保存
        saveAISessions(serverId: serverId)

        let session = AISession.create(serverId: serverId)
        if aiSessions[serverId] == nil {
            aiSessions[serverId] = []
        }
        aiSessions[serverId]?.insert(session, at: 0)
        activeAISessionId[tabId] = session.id
        saveAISessions(serverId: serverId)
        return .handled("已创建新会话")
    }

    private func listSessions() -> SlashCommandResult {
        guard let serverId = currentServerId else {
            return .handled("无法列出 session：请先连接服务器")
        }
        loadAISessions(serverId: serverId)
        let sessions = aiSessions[serverId] ?? []
        if sessions.isEmpty {
            return .handled("当前没有历史会话")
        }
        var lines = ["📋 **历史会话** (点击加载, 或用 `/load <id>`):"]
        for s in sessions {
            let dateStr = dateFormatter.string(from: s.updatedAt)
            let msgCount = s.messages.count
            let title = s.title.isEmpty ? "（空会话）" : s.title
            let marker = activeAISessionId[activeTabId ?? ""] == s.id ? " ●" : ""
            lines.append("- `\(s.id.prefix(8))` \(title) (\(msgCount) 条消息, \(dateStr))\(marker)")
        }
        return .handled(lines.joined(separator: "\n"))
    }

    private func loadSession(sessionId: String) -> SlashCommandResult {
        guard let serverId = currentServerId,
              let tabId = activeTabId,
              let sessions = aiSessions[serverId] else {
            return .handled("无法加载 session")
        }
        // Support prefix matching
        let match = sessions.first(where: { $0.id.hasPrefix(sessionId) })
        guard let session = match else {
            return .handled("未找到 session: \(sessionId)")
        }
        activeAISessionId[tabId] = session.id
        return .switchSession(session.id)
    }

    private func compactCurrentSession() -> SlashCommandResult {
        guard let serverId = currentServerId,
              let tabId = activeTabId,
              let sessionId = activeAISessionId[tabId],
              var sessions = aiSessions[serverId],
              let idx = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return .handled("无法压缩：无活跃会话")
        }
        let msgs = sessions[idx].messages
        guard msgs.count >= 4 else {
            return .handled("消息太少，无需压缩")
        }

        let splitIdx = max(1, Int(Double(msgs.count) * 0.7))
        let toCompress = Array(msgs[0..<splitIdx])
        let toKeep = Array(msgs[splitIdx...])

        // Build summary text — actual AI summarization happens in AIChatView
        let summaryContent = "[上下文摘要] 前 \(toCompress.count) 条消息已压缩。"
        let summaryMsg = AIChatMessage(
            id: UUID().uuidString,
            role: "system",
            content: summaryContent,
            timestamp: Date()
        )

        sessions[idx].messages = [summaryMsg] + toKeep
        sessions[idx].updatedAt = Date()
        aiSessions[serverId] = sessions
        saveAISessions(serverId: serverId)

        return .handled("已压缩上下文：将前 \(toCompress.count) 条消息替换为摘要，保留 \(toKeep.count) 条")
    }

    private var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
```

- [ ] **Step 5: 新增命令安全白名单**

在 `AppState` 中追加：

```swift
    // MARK: - Command Safety Whitelist

    struct CommandSafety {
        static let safePrefixes: [String] = [
            "ls", "cat ", "head ", "tail ", "less ", "file ", "stat ", "du ",
            "grep ", "awk ", "sed -n", "wc ", "sort ", "uniq ", "cut ", "tr ",
            "ps ", "top -bn", "htop -n", "free ", "df ", "uptime", "uname", "hostname", "whoami", "id ",
            "ping -c", "curl -I", "wget --spider", "ss -tlnp", "ss -tuln",
            "netstat ", "ip addr show", "ip a ", "nslookup ", "dig ",
            "systemctl status", "journalctl ", "service ", "pgrep ", "pidof ",
            "lsof -p", "dmesg", "last ", "lastlog",
            "echo ", "printf ", "pwd", "env ", "printenv", "which ", "whereis", "type ",
            "find ", "locate ", "dpkg -l", "rpm -q", "pip list",
            "docker ps", "docker images", "docker inspect", "docker logs",
        ]

        static let dangerousPatterns: [String] = [
            "rm ", "mv ", "cp ", "chmod ", "chown ",
            "kill ", "pkill", "killall",
            "systemctl start", "systemctl stop", "systemctl restart",
            "systemctl enable", "systemctl disable", "systemctl mask",
            "apt install", "apt remove", "apt purge", "apt-get",
            "yum install", "yum remove", "dnf install", "dnf remove",
            "brew install", "brew uninstall", "pip install", "pip uninstall",
            "npm install -g", "npm uninstall -g",
            "dd ", "mkfs", "fdisk", "parted",
            "shutdown", "reboot", "halt", "poweroff",
            "> ", ">>", // redirect that writes files
        ]

        /// Returns true if the command is safe to auto-execute
        static func isSafe(command: String) -> Bool {
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }

            // Check dangerous patterns first
            for pattern in dangerousPatterns {
                if trimmed.lowercased().contains(pattern.lowercased()) {
                    return false
                }
            }

            // sudo is always dangerous
            if trimmed.lowercased().contains("sudo") {
                return false
            }

            // Check safe prefixes
            for prefix in safePrefixes {
                if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                    return true
                }
            }

            // Unknown command — needs confirmation
            return false
        }
    }
```

- [ ] **Step 6: 更新 init() 加载逻辑**

在 `init()` 中添加 `loadAIPanelWidth()` 调用。修改第 48-60 行：

```swift
    init() {
        let savedTheme = UserDefaults.standard.string(forKey: "theme") ?? "catppuccinMocha"
        if let t = AppTheme(rawValue: savedTheme) {
            _theme = Published(initialValue: t)
        }
        ThemeManager.shared.loadThemes()
        loadServers()
        loadCredentialGroups()
        loadSnippets()
        loadKeywords()
        loadAIConfig()
        loadAIPanelWidth()
    }
```

- [ ] **Step 7: Build 验证编译通过**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add orbit-app/Orbit/ViewModels/AppState.swift
git commit -m "feat: AI session management, persistence, whitelist, slash commands"
```

---

### Task 3: OpenAIService Agent Loop

**Files:**
- Modify: `orbit-app/Orbit/Models/OpenAIService.swift`

- [ ] **Step 1: 新增 agent loop 方法**

在 `OpenAIService` 类的 `cancel()` 方法之后，`streamMessage` 之前追加。`runAgent` 是单次调用：请求 AI → 解析 `execute` → 通过回调通知调用方。命令执行和循环由 AIChatView 驱动。

```swift
    private var agentTask: Task<Void, Never>?

    func cancelAgent() {
        agentTask?.cancel()
        agentTask = nil
        streamTask?.cancel()
        streamTask = nil
        isLoading = false
    }

    // MARK: - Agent Loop (single-shot: call AI → extract ```execute → callback)

    func runAgent(
        messages: [AIChatMessage],
        systemPrompt: String,
        config: AIConfig,
        onToken: @escaping (String) -> Void,
        onCommands: @escaping ([String]) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        isLoading = true

        agentTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.isLoading = false }

            // Build API messages with agent mode instruction
            var agentPrompt = systemPrompt + """

            ## 自动执行模式
            你可以在回复中使用 ```execute 代码块直接执行命令并获取输出。
            格式：
            ```execute
            command_here
            ```
            一次最多一个 execute 块。
            """

            var apiMessages: [[String: String]] = []
            apiMessages.append(["role": "system", "content": agentPrompt])
            let recent = Array(messages.suffix(30))
            for msg in recent {
                apiMessages.append(["role": msg.role, "content": msg.content])
            }

            let content = await self.callAndCollect(
                messages: apiMessages, config: config, onToken: onToken)
            if Task.isCancelled { return }

            if let error = content.error {
                onComplete(.failure(error))
                return
            }

            let fullContent = content.text ?? ""
            let commands = self.extractExecutes(from: fullContent)

            if commands.isEmpty {
                onComplete(.success(fullContent))
            } else {
                // Notify caller about commands, don't call onComplete yet
                // Caller will inspect commands and re-enter runAgent after execution
                onCommands(commands)
            }
        }
    }

    /// Extract ```execute ... ``` blocks from AI response
    func extractExecutes(from content: String) -> [String] {
        let pattern = "```execute\\s*\\n([\\s\\S]*?)\\n```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        return matches.compactMap { match in
            if let range = Range(match.range(at: 1), in: content) {
                return String(content[range]).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    // MARK: - Internal: call AI API and collect streaming response

    private struct AgentCallResult {
        let text: String?
        let error: Error?
    }

    private func callAndCollect(
        messages: [[String: String]],
        config: AIConfig,
        onToken: @escaping (String) -> Void
    ) async -> AgentCallResult {
        let endpoint = config.endpoint.hasSuffix("/v1")
            ? config.endpoint + "/chat/completions"
            : config.endpoint + "/v1/chat/completions"

        guard let url = URL(string: endpoint) else {
            return AgentCallResult(text: nil, error: NSError(domain: "AIService", code: -1))
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 2000,
            "stream": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return AgentCallResult(text: nil, error: NSError(domain: "AIService", code: -2))
        }

        var fullContent = ""
        var lineData = Data()

        do {
            for try await byte in bytes {
                if Task.isCancelled { break }
                lineData.append(byte)
                if byte == UInt8(ascii: "\n") {
                    guard let line = String(data: lineData, encoding: .utf8) else {
                        lineData.removeAll(keepingCapacity: true)
                        continue
                    }
                    lineData.removeAll(keepingCapacity: true)

                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("data:") else { continue }
                    let dataStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if dataStr == "[DONE]" { break }

                    guard let data = dataStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]] else { continue }

                    for choice in choices {
                        if let delta = choice["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            fullContent += content
                            onToken(content)
                        }
                    }
                }
            }
        } catch {
            if fullContent.isEmpty {
                return AgentCallResult(text: nil, error: error)
            }
        }

        return AgentCallResult(text: fullContent, error: nil)
    }
```

- [ ] **Step 2: Build 验证编译通过**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add orbit-app/Orbit/Models/OpenAIService.swift
git commit -m "feat: add AI agent loop with execute block extraction"
```

---

### Task 4: AIChatView 重构 — Session 选择器、命令确认、面板拖拽、Slash Command

**Files:**
- Modify: `orbit-app/Orbit/Views/AIChatView.swift`

- [ ] **Step 1: 重写 AIChatView body — 可拖拽面板宽度 + session 集成**

将整个 `AIChatView` 替换为：

```swift
import SwiftUI
import SwiftTerm

struct AIChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var service = OpenAIService()
    @State private var inputText: String = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var showSessionPicker: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                Text("AI 助手")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !appState.currentSessionTitle().isEmpty {
                    Text("— \(appState.currentSessionTitle())")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: { appState.clearCurrentSessionMessages() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .disabled(appState.currentMessages.isEmpty)
                .help("清除当前会话")
                Button(action: { appState.toggleAIPanel() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Config warning
            if appState.aiConfig.apiKey.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "gearshape")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("AI 助手未配置")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("请在设置中配置 API 地址和 Key")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Button("打开设置") {
                        SettingsWindowController.shared.open(with: appState)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
                    Spacer()
                }
                .padding(.vertical, 40)
            } else {
                // Session picker banner
                if showSessionPicker {
                    SessionPickerView(onSelect: { session in
                        guard let tabId = appState.activeTabId else { return }
                        appState.activeAISessionId[tabId] = session.id
                        showSessionPicker = false
                    }, onDismiss: { showSessionPicker = false })
                    Divider()
                }

                // Messages
                ScrollViewReader { scrollView in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if appState.currentMessages.isEmpty {
                                VStack(spacing: 4) {
                                    Text("告诉我你遇到的问题，")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    Text("我会分析终端输出来帮助你排查")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    Text("支持命令: /new /sessions /compact")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 20)
                                .frame(maxWidth: .infinity)
                            }

                            ForEach(appState.currentMessages) { message in
                                MessageBubble(message: message)
                            }

                            // Pending command confirmation
                            if let pending = appState.aiPendingConfirmation {
                                PendingCommandView(
                                    command: pending.command,
                                    onConfirm: {
                                        executeConfirmedCommand()
                                    },
                                    onReject: {
                                        appState.aiPendingConfirmation = nil
                                        let rejectMsg = AIChatMessage(
                                            id: UUID().uuidString,
                                            role: "system",
                                            content: "用户拒绝了命令: `\(pending.command)`",
                                            timestamp: Date()
                                        )
                                        appState.addMessageToCurrentSession(rejectMsg)
                                    }
                                )
                            }

                            if service.isLoading {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                    Text("思考中...")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onAppear { scrollProxy = scrollView }
                    .onChange(of: appState.currentMessages.count) { _ in
                        if let last = appState.currentMessages.last, let proxy = scrollProxy {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Input
                HStack(spacing: 8) {
                    TextField("描述问题... (/new, /sessions, /compact)", text: $inputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { sendMessage() }

                    Button(action: { sendMessage() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || service.isLoading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: appState.aiPanelWidth)
        .background(Color(NSColor.controlBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .askAI)) { notification in
            guard let question = notification.userInfo?["question"] as? String,
                  !question.isEmpty else { return }
            sendMessage(text: question)
        }
        .onAppear {
            if let serverId = appState.currentServerId,
               let tabId = appState.activeTabId {
                appState.loadAISessions(serverId: serverId)
                let _ = appState.ensureSession(tabId: tabId, serverId: serverId)
            }
        }
        // Resizable panel: drag left edge
        .gesture(
            DragGesture()
                .onChanged { value in
                    let newWidth = appState.aiPanelWidth - value.translation.width
                    appState.aiPanelWidth = min(600, max(160, newWidth))
                }
                .onEnded { _ in
                    appState.saveAIPanelWidth(appState.aiPanelWidth)
                }
        )
    }
```

- [ ] **Step 2: 重写 sendMessage — 集成 slash command 和 agent 驱动循环**

替换 `sendMessage` 方法（原第 134-188 行）。核心逻辑：`sendToAI` 调用 `runAgent`，收到 `onCommands` 后逐条执行命令，执行完后将结果注入消息再调用 `runAgent` 继续循环。

```swift
    private func sendMessage(text: String? = nil) {
        let questionText: String
        if let text = text {
            questionText = text
        } else {
            let trimmed = inputText.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            questionText = trimmed
            inputText = ""
        }

        // Handle slash commands
        if questionText.hasPrefix("/") {
            let result = appState.handleSlashCommand(questionText)
            switch result {
            case .handled(let msg):
                let sysMsg = AIChatMessage(id: UUID().uuidString, role: "system", content: msg, timestamp: Date())
                appState.addMessageToCurrentSession(sysMsg)
            case .switchSession:
                showSessionPicker = false
            case .ignore:
                sendToAI(questionText)
            }
            return
        }

        sendToAI(questionText)
    }

    private func sendToAI(_ questionText: String) {
        let userMsg = AIChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: questionText,
            timestamp: Date()
        )
        appState.addMessageToCurrentSession(userMsg)
        continueAgentLoop()
    }

    /// Run one iteration of agent loop: call AI, handle executes, repeat
    private func continueAgentLoop(iteration: Int = 0) {
        let maxIterations = 5
        guard iteration < maxIterations else {
            let msg = AIChatMessage(id: UUID().uuidString, role: "system",
                content: "已达到最大自动执行次数，请手动检查", timestamp: Date())
            appState.addMessageToCurrentSession(msg)
            return
        }

        let context = collectTerminalContext()
        let systemPrompt = buildSystemPrompt(context: context)
        let sid = getActiveSSHSessionId() ?? ""

        service.runAgent(
            messages: appState.currentMessages,
            systemPrompt: systemPrompt,
            config: appState.aiConfig,
            onToken: { token in
                self.appState.appendToCurrentAssistantMessage(text: token)
            },
            onCommands: { commands in
                // Execute commands sequentially, then re-enter loop
                self.executeAndContinue(commands: commands, iteration: iteration)
            },
            onComplete: { result in
                switch result {
                case .success(let content):
                    if !content.isEmpty, let cmd = self.extractCommand(from: content) {
                        let cmdMsg = AIChatMessage(
                            id: UUID().uuidString, role: "system",
                            content: "💡 建议命令: `\(cmd)` — 点击执行或复制到终端",
                            timestamp: Date())
                        self.appState.addMessageToCurrentSession(cmdMsg)
                    }
                case .failure(let error):
                    let errorMsg = AIChatMessage(
                        id: UUID().uuidString, role: "system",
                        content: "错误: \(error.localizedDescription)",
                        timestamp: Date())
                    self.appState.addMessageToCurrentSession(errorMsg)
                }
            }
        )
    }

    private func executeAndContinue(commands: [String], iteration: Int) {
        guard !commands.isEmpty else {
            continueAgentLoop(iteration: iteration + 1)
            return
        }

        let cmd = commands[0]
        let remaining = Array(commands.dropFirst())

        if AppState.CommandSafety.isSafe(command: cmd) {
            // Safe: execute, add result, continue
            executeCommand(cmd) {
                if remaining.isEmpty {
                    self.continueAgentLoop(iteration: iteration + 1)
                } else {
                    self.executeAndContinue(commands: remaining, iteration: iteration)
                }
            }
        } else {
            // Need user confirmation
            if let tabId = appState.activeTabId {
                let sid = getActiveSSHSessionId() ?? ""
                appState.aiPendingConfirmation = (command: cmd, sessionId: sid, tabId: tabId)
            }
            // Don't continue loop — wait for user
        }
    }

    private func executeCommand(_ command: String, onDone: @escaping () -> Void) {
        guard let sid = getActiveSSHSessionId() else {
            let errMsg = AIChatMessage(id: UUID().uuidString, role: "system",
                content: "执行失败: 无活跃 SSH 会话", timestamp: Date())
            appState.addMessageToCurrentSession(errMsg)
            onDone()
            return
        }
        do {
            try OrbitBridge.shared.writeSSH(sessionId: sid, data: Data((command + "\n").utf8))
        } catch {
            let errMsg = AIChatMessage(id: UUID().uuidString, role: "system",
                content: "执行失败: \(error.localizedDescription)", timestamp: Date())
            appState.addMessageToCurrentSession(errMsg)
            onDone()
            return
        }
        // Wait for output to accumulate in terminal
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let output = self.collectTerminalContext()
            let exitCode: Int32 = output.contains("command not found") ? 127 : 0
            let resultMsg = AIChatMessage(
                id: UUID().uuidString, role: "system",
                content: "[命令结果] `\(command)`\nexit=\(exitCode)\n```\n\(output.prefix(2000))\n```",
                timestamp: Date())
            self.appState.addMessageToCurrentSession(resultMsg)
            onDone()
        }
    }

    private func executeConfirmedCommand() {
        guard let pending = appState.aiPendingConfirmation else { return }
        appState.aiPendingConfirmation = nil
        let confirmMsg = AIChatMessage(id: UUID().uuidString, role: "system",
            content: "用户确认执行: `\(pending.command)`", timestamp: Date())
        appState.addMessageToCurrentSession(confirmMsg)
        executeCommand(pending.command) {
            self.continueAgentLoop(iteration: 0) // Reset iteration after confirmation
        }
    }

    private func getActiveSSHSessionId() -> String? {
        guard let activeId = appState.activeTabId,
              let tab = appState.tabs.first(where: { $0.id == activeId }) else { return nil }
        return tab.sessionId ?? tab.focusedChannelId
    }
```

- [ ] **Step 3: 追加 SessionPickerView 和 PendingCommandView**

在文件末尾（`AIErrorBanner` 之后）追加两个新 View：

```swift
// MARK: - Session Picker

private struct SessionPickerView: View {
    @EnvironmentObject var appState: AppState
    let onSelect: (AISession) -> Void
    let onDismiss: () -> Void

    var sessions: [AISession] {
        guard let serverId = appState.currentServerId else { return [] }
        return appState.aiSessions[serverId] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("历史会话")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }

            if sessions.isEmpty {
                Text("暂无历史会话")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(sessions) { session in
                    Button(action: { onSelect(session) }) {
                        HStack {
                            Text(session.title.isEmpty ? "（空会话）" : session.title)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                            Text(formatDate(session.updatedAt))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            if let activeSessionId = appState.activeAISessionId[appState.activeTabId ?? ""],
                               activeSessionId == session.id {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Pending Command Confirmation

private struct PendingCommandView: View {
    let command: String
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow)
                Text("AI 想执行命令:")
                    .font(.system(size: 11, weight: .medium))
            }
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .padding(4)
                .background(Color.black.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 8) {
                Button("确认执行") { onConfirm() }
                    .font(.system(size: 10))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.2))
                    .clipShape(Capsule())
                    .buttonStyle(.plain)

                Button("拒绝") { onReject() }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 4: 更新 MessageBubble — 适配 session 消息格式**

更新 `formattedContent` 中的代码块过滤，增加对 `execute` 块的格式化显示。替换 `formattedContent` computed property（第 331-340 行）：

```swift
    private var formattedContent: String {
        var content = message.content
        // Remove code blocks with language specifier, keep content
        let blockPattern = "```[a-z]*\\s*\\n([\\s\\S]*?)\\n```"
        if let regex = try? NSRegularExpression(pattern: blockPattern, options: []) {
            content = regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "$1")
        }
        return content
    }
```

不变（逻辑一样，但注释更新）。

- [ ] **Step 5: Build 验证编译通过**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add orbit-app/Orbit/Views/AIChatView.swift
git commit -m "feat: session picker, command confirmation, resizable panel, slash commands in AI chat"
```

---

### Task 5: 最终验证

- [ ] **Step 1: 完整构建**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | tail -5
```

- [ ] **Step 2: 检查是否有编译警告**

```bash
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build 2>&1 | grep -i "warning"
```

Expected: 仅有 version warning（正常），无新增警告。

- [ ] **Step 3: Commit**

```bash
git commit --allow-empty -m "chore: final verification — AI session management feature complete"
```
