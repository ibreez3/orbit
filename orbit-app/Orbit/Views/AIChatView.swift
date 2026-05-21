import SwiftUI
import SwiftTerm

struct AIChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var service = OpenAIService()
    @State private var inputText: String = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var showSessionPicker: Bool = false
    @State private var agentIteration: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            // Resize handle
            Rectangle()
                .fill(Color.primary.opacity(0.0))
                .frame(width: 6)
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
                            let newWidth = appState.aiPanelWidth - value.translation.width
                            appState.aiPanelWidth = min(600, max(160, newWidth))
                        }
                        .onEnded { _ in
                            appState.saveAIPanelWidth(appState.aiPanelWidth)
                        }
                )

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

                            if !service.streamingText.isEmpty {
                                MessageBubble(message: AIChatMessage(
                                    id: "_streaming", role: "assistant",
                                    content: service.streamingText, timestamp: Date()))
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .askAI)) { notification in
            guard !service.isLoading,
                  let question = notification.userInfo?["question"] as? String,
                  !question.isEmpty else { return }
            sendMessage(text: question)
        }
        .onAppear {
            let serverId = appState.currentServerId
            appState.loadAISessions(serverId: serverId)
            let tabId = appState.activeTabId ?? "_standalone_tab_"
            let _ = appState.ensureSession(tabId: tabId, serverId: serverId)
        }
    }

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
                if questionText.trimmingCharacters(in: .whitespaces) == "/sessions" {
                    showSessionPicker = true
                }
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
        agentIteration = 0
        continueAgentLoop()
    }

    /// Run one iteration of agent loop: call AI → handle executes → repeat
    private func continueAgentLoop() {
        let maxIterations = 5
        guard agentIteration < maxIterations else {
            let msg = AIChatMessage(id: UUID().uuidString, role: "system",
                content: "已达到最大自动执行次数，请手动检查", timestamp: Date())
            appState.addMessageToCurrentSession(msg)
            return
        }

        let context = collectTerminalContext()
        let hasActiveSSH = getActiveSSHSessionId() != nil
        let systemPrompt = buildSystemPrompt(context: context, agentMode: hasActiveSSH)

        service.streamingText = ""
        service.runAgent(
            messages: appState.currentMessages,
            systemPrompt: systemPrompt,
            config: appState.aiConfig,
            onToken: { token in
                self.service.streamingText += token
            },
            onCommands: { commands in
                // Commit streaming text before executing commands
                if !self.service.streamingText.isEmpty {
                    self.appState.addMessageToCurrentSession(AIChatMessage(
                        id: UUID().uuidString, role: "assistant",
                        content: self.service.streamingText, timestamp: Date()))
                    self.service.streamingText = ""
                }
                self.executeCommandsAndContinue(commands: commands)
            },
            onComplete: { result in
                switch result {
                case .success(let content):
                    if !self.service.streamingText.isEmpty {
                        self.appState.addMessageToCurrentSession(AIChatMessage(
                            id: UUID().uuidString, role: "assistant",
                            content: self.service.streamingText, timestamp: Date()))
                        self.service.streamingText = ""
                    }
                    if !content.isEmpty, let cmd = self.extractCommand(from: content) {
                        let cmdMsg = AIChatMessage(
                            id: UUID().uuidString, role: "system",
                            content: "💡 建议命令: `\(cmd)` — 点击执行或复制到终端",
                            timestamp: Date())
                        self.appState.addMessageToCurrentSession(cmdMsg)
                    }
                    self.appState.saveAISessions(serverId: self.appState.currentServerId)
                case .failure(let error):
                    if !self.service.streamingText.isEmpty {
                        self.appState.addMessageToCurrentSession(AIChatMessage(
                            id: UUID().uuidString, role: "assistant",
                            content: self.service.streamingText, timestamp: Date()))
                        self.service.streamingText = ""
                    }
                    let errorMsg = AIChatMessage(
                        id: UUID().uuidString, role: "system",
                        content: "错误: \(error.localizedDescription)",
                        timestamp: Date())
                    self.appState.addMessageToCurrentSession(errorMsg)
                }
            }
        )
    }

    private func executeCommandsAndContinue(commands: [String]) {
        guard let first = commands.first else {
            agentIteration += 1
            continueAgentLoop()
            return
        }
        let remaining = Array(commands.dropFirst())

        if AppState.CommandSafety.isSafe(command: first) {
            // Safe: execute, add result, continue
            executeCommand(first) {
                if remaining.isEmpty {
                    self.agentIteration += 1
                    self.continueAgentLoop()
                } else {
                    self.executeCommandsAndContinue(commands: remaining)
                }
            }
        } else {
            // Need user confirmation — pause agent loop
            if let tabId = appState.activeTabId {
                let sid = getActiveSSHSessionId() ?? ""
                appState.aiPendingConfirmation = (command: first, sessionId: sid, tabId: tabId)
            }
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
        let capturedTabId = appState.activeTabId
        let capturedSessionId = capturedTabId.flatMap { appState.activeAISessionId[$0] }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard appState.activeAISessionId[capturedTabId ?? ""] == capturedSessionId else {
                onDone()
                return
            }
            let output = self.collectTerminalContext()
            let exitCode: Int32 = output.contains("command not found") ? 127 : 0
            let resultMsg = AIChatMessage(
                id: UUID().uuidString, role: "system",
                content: "[命令结果] `\(command)`\nexit=\(exitCode)\n```\n\(output.prefix(2000))\n```",
                timestamp: Date())
            self.appState.addMessageToCurrentSession(resultMsg, shouldSave: false)
            onDone()
        }
    }

    private func executeConfirmedCommand() {
        guard let pending = appState.aiPendingConfirmation else { return }
        appState.aiPendingConfirmation = nil
        let confirmMsg = AIChatMessage(id: UUID().uuidString, role: "system",
            content: "用户确认执行: `\(pending.command)`", timestamp: Date())
        appState.addMessageToCurrentSession(confirmMsg)
        agentIteration = 0 // Reset iteration counter after manual confirmation
        executeCommand(pending.command) {
            self.agentIteration += 1
            self.continueAgentLoop()
        }
    }

    private func getActiveSSHSessionId() -> String? {
        guard let activeId = appState.activeTabId,
              let tab = appState.tabs.first(where: { $0.id == activeId }) else { return nil }
        return tab.sessionId ?? tab.focusedChannelId
    }

    private func collectTerminalContext() -> String {
        guard let activeId = appState.activeTabId,
              let tab = appState.tabs.first(where: { $0.id == activeId }),
              let sid = tab.sessionId ?? tab.focusedChannelId else {
            return "（无活跃终端会话）"
        }

        guard let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView else {
            return "（终端会话已连接，暂无输出）"
        }
        let term = tv.getTerminal()

        let visibleRows = term.rows
        let contextLines = min(visibleRows * 2, 100)
        let startRow = max(0, visibleRows - contextLines)

        var lines: [String] = []
        for row in startRow..<visibleRows {
            if let line = term.getLine(row: row) {
                let text = line.translateToString(trimRight: true)
                lines.append(text)
            }
        }

        let result = lines.joined(separator: "\n")
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "（终端暂无输出）"
        }


        return result
    }

    private func buildSystemPrompt(context: String, agentMode: Bool) -> String {
        var prompt = """
        你是一个 SSH 终端助手，帮助用户排查服务器问题。你可以看到用户的终端输出。

        ## 当前终端输出（最近内容）
        \(context)

        ## 你的职责
        1. 分析终端输出中的错误、警告或异常
        2. 根据用户的问题提供排查建议
        3. 给出可直接执行的命令（用 ```command 代码块包裹）
        4. 解释每个命令的作用

        ## 注意
        - 只建议安全的命令（禁止 rm -rf /、mkfs、dd 写磁盘、shutdown、reboot 等危险操作）
        - 如果必须使用危险命令，明确警告用户
        - 回答简洁，优先给出可执行的命令
        """
        if agentMode {
            prompt += """

        ## 自动执行模式
        你已连接到终端，可以使用 ```execute 代码块让命令在终端中自动执行并获取输出。
        格式：
        ```execute
        command_here
        ```
        每条回复最多一个 execute 块。只在需要获取系统信息时使用。
        """
        }
        return prompt
    }

    private func extractCommand(from content: String) -> String? {
        let pattern = "```command\\s*\\n([\\s\\S]*?)\\n```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) else {
            return nil
        }
        if let range = Range(match.range(at: 1), in: content) {
            return String(content[range]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

private struct MessageBubble: View {
    let message: AIChatMessage
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(alignment: .top) {
            if message.role != "user" {
                Circle()
                    .fill(message.role == "assistant" ? Color.blue : Color.gray)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: message.role == "assistant" ? "sparkles" : "info.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                if let md = formattedMarkdown {
                    Text(md)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(formattedContent)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if message.role == "system", message.content.contains("建议命令") {
                    HStack(spacing: 4) {
                        Button("执行") {
                            if let cmd = extractSuggestedCommand(from: message.content) {
                                if let activeId = appState.activeTabId,
                                   let tab = appState.tabs.first(where: { $0.id == activeId }),
                                   let sid = tab.sessionId ?? tab.focusedChannelId,
                                   let tv = OrbitBridge.shared.terminalViewCache[sid] as? OrbitTerminalView {
                                    appState.insertSnippetCommand(cmd + "\r", into: tv)
                                }
                            }
                        }
                        .font(.system(size: 10))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Capsule())
                        .buttonStyle(.plain)

                        Button("复制") {
                            if let cmd = extractSuggestedCommand(from: message.content) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(8)
            .background(
                message.role == "user"
                    ? Color.accentColor.opacity(0.15)
                    : Color.primary.opacity(0.06)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)

            if message.role == "user" {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                    )
            }
        }
    }

    private var formattedContent: String {
        var content = message.content
        let blockPattern = "```[a-z]*\\s*\\n([\\s\\S]*?)\\n```"
        if let regex = try? NSRegularExpression(pattern: blockPattern, options: []) {
            content = regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "$1")
        }
        return content
    }

    private var formattedMarkdown: AttributedString? {
        let md = formattedContent
        return try? AttributedString(markdown: md,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }

    private func extractSuggestedCommand(from content: String) -> String? {
        // Extract text between backticks
        let pattern = "`([^`]+)`"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) else {
            return nil
        }
        if let range = Range(match.range(at: 1), in: content) {
            return String(content[range])
        }
        return nil
    }
}

// MARK: - Error Banner

struct AIErrorBanner: View {
    let errorText: String
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button(action: {
            appState.activeTabError = nil
            appState.submitAIQuestion("请分析这个错误:\n\(errorText)")
        }) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                Text("AI 分析此错误")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Button(action: {
                    appState.activeTabError = nil
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session Picker

private struct SessionPickerView: View {
    @EnvironmentObject var appState: AppState
    let onSelect: (AISession) -> Void
    let onDismiss: () -> Void

    var sessions: [AISession] {
        let serverId = appState.currentServerId
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
