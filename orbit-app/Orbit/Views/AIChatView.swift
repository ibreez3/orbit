import SwiftUI
import SwiftTerm

struct AIChatView: View {
    @EnvironmentObject var aiState: AIState
    @EnvironmentObject var tabState: TabState
    let appState: AppState
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
                            let newWidth = aiState.aiPanelWidth - value.translation.width
                            aiState.aiPanelWidth = min(600, max(160, newWidth))
                        }
                        .onEnded { _ in
                            appState.saveAIPanelWidth(aiState.aiPanelWidth)
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
            if aiState.aiConfig.apiKey.isEmpty {
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
                    SessionPickerView(appState: appState,
                        onSelect: { session in
                        guard let tabId = appState.activeTabId else { return }
                        aiState.activeAISessionId[tabId] = session.id
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
                                MessageBubble(message: message, appState: appState)
                            }

                            if !service.streamingText.isEmpty {
                                MessageBubble(message: AIChatMessage(
                                    id: "_streaming", role: "assistant",
                                    content: service.streamingText, timestamp: Date()),
                                    isStreaming: true, appState: appState)
                            }

                            // Pending command confirmation
                            if let pending = aiState.aiPendingConfirmation {
                                PendingCommandView(
                                    pending: pending,
                                    onConfirm: {
                                        executeConfirmedCommand()
                                    },
                                    onReject: {
                                        appState.appendAuditEvent(
                                            category: .aiAction,
                                            action: "command_confirmation",
                                            target: pending.command,
                                            result: .denied,
                                            summary: "用户拒绝 AI 命令执行"
                                        )
                                        aiState.aiPendingConfirmation = nil
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
            .frame(width: aiState.aiPanelWidth)
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
                content: "已达到最大 AI 工具调用轮次，请手动检查", timestamp: Date())
            appState.addMessageToCurrentSession(msg)
            return
        }

        let sessionContext = appState.activeSessionContext
        let context = collectAIContext(for: sessionContext)
        let canExecuteInTerminal = sessionContext.kind != .database && sessionContext.sessionId != nil
        let systemPrompt = buildSystemPrompt(
            context: context,
            agentMode: canExecuteInTerminal,
            sessionContext: sessionContext
        )

        service.streamingText = ""
        service.runAgent(
            messages: appState.currentMessages,
            systemPrompt: systemPrompt,
            config: aiState.aiConfig,
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
                            content: "💡 建议命令: `\(cmd)` — 可插入终端，运行前需要确认",
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

        if remaining.isEmpty {
            requestCommandConfirmation(first, source: "agent_execute")
        } else {
            let skippedCount = remaining.count
            requestCommandConfirmation(first, source: "agent_execute")
            let msg = AIChatMessage(
                id: UUID().uuidString,
                role: "system",
                content: "AI 请求执行多条命令。已暂停在第一条命令，其余 \(skippedCount) 条需在确认后重新评估。",
                timestamp: Date()
            )
            appState.addMessageToCurrentSession(msg)
        }
    }

    private func requestCommandConfirmation(_ command: String, source: String) {
        guard let tabId = appState.activeTabId else {
            appState.appendAuditEvent(
                category: .aiAction,
                action: "command_confirmation",
                target: command,
                result: .failed,
                summary: "AI 请求执行命令失败：无活动 Tab"
            )
            let errMsg = AIChatMessage(id: UUID().uuidString, role: "system",
                content: "执行失败: 无活动 Tab", timestamp: Date())
            appState.addMessageToCurrentSession(errMsg)
            return
        }

        let context = appState.activeSessionContext
        guard context.kind != .database else {
            let errMsg = AIChatMessage(id: UUID().uuidString, role: "system",
                content: "Database AI 暂不支持自动执行 SQL。请复制建议到 SQL 编辑器手动确认。", timestamp: Date())
            appState.addMessageToCurrentSession(errMsg)
            return
        }
        guard let sid = context.sessionId else {
            appState.appendAuditEvent(
                category: .aiAction,
                action: "command_confirmation",
                target: command,
                result: .failed,
                summary: "AI 请求执行命令失败：无活跃终端会话"
            )
            let errMsg = AIChatMessage(id: UUID().uuidString, role: "system",
                content: "执行失败: 无活跃终端会话", timestamp: Date())
            appState.addMessageToCurrentSession(errMsg)
            return
        }
        let riskReason = AppState.CommandSafety.riskReason(command: command)
        aiState.aiPendingConfirmation = PendingAICommand(
            command: command,
            sessionId: sid,
            tabId: tabId,
            contextIdentity: context.identity,
            serverName: context.serverName,
            host: context.host,
            isHighRisk: riskReason != nil,
            riskReason: riskReason
        )
        appState.appendAuditEvent(
            category: .aiAction,
            action: "command_confirmation",
            target: command,
            result: .requested,
            summary: "AI 请求执行命令，需要用户确认（\(source)）"
        )
    }

    private func executeCommand(_ command: String, pending: PendingAICommand, onDone: @escaping () -> Void) {
        guard pending.tabId == appState.activeTabId,
              pending.sessionId == appState.activeSessionContext.sessionId,
              pending.contextIdentity == appState.activeSessionContext.identity else {
            let errMsg = AIChatMessage(id: UUID().uuidString, role: "system",
                content: "执行已取消: 会话上下文已切换", timestamp: Date())
            appState.addMessageToCurrentSession(errMsg)
            appState.appendAuditEvent(
                category: .terminalCommand,
                action: "ai_command_execute",
                target: command,
                result: .canceled,
                summary: "AI 命令执行已取消：会话上下文已切换"
            )
            onDone()
            return
        }
        do {
            try appState.sendTerminalInput(command + "\n", sessionId: pending.sessionId)
        } catch {
            let errMsg = AIChatMessage(id: UUID().uuidString, role: "system",
                content: "执行失败: \(error.localizedDescription)", timestamp: Date())
            appState.addMessageToCurrentSession(errMsg)
            appState.appendAuditEvent(
                category: .terminalCommand,
                action: "ai_command_execute",
                target: command,
                result: .failed,
                summary: "AI 命令写入终端失败：\(error.localizedDescription)"
            )
            onDone()
            return
        }
        // Wait for output to accumulate in terminal
        let capturedTabId = pending.tabId
        let capturedSessionId = aiState.activeAISessionId[capturedTabId]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard self.appState.activeTabId == pending.tabId,
                  self.appState.activeSessionContext.sessionId == pending.sessionId,
                  aiState.activeAISessionId[capturedTabId] == capturedSessionId else {
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
            self.appState.appendAuditEvent(
                category: .terminalCommand,
                action: "ai_command_execute",
                target: command,
                result: exitCode == 0 ? .succeeded : .failed,
                summary: "AI 命令已执行，exit=\(exitCode)"
            )
            onDone()
        }
    }

    private func executeConfirmedCommand() {
        guard let pending = aiState.aiPendingConfirmation else { return }
        aiState.aiPendingConfirmation = nil
        guard pending.tabId == appState.activeTabId,
              pending.sessionId == appState.activeSessionContext.sessionId,
              pending.contextIdentity == appState.activeSessionContext.identity else {
            let staleMsg = AIChatMessage(id: UUID().uuidString, role: "system",
                content: "执行已取消: 会话上下文已切换", timestamp: Date())
            appState.addMessageToCurrentSession(staleMsg)
            appState.appendAuditEvent(
                category: .aiAction,
                action: "command_confirmation",
                target: pending.command,
                result: .canceled,
                summary: "用户确认前会话上下文已切换，AI 命令未执行"
            )
            return
        }
        let confirmMsg = AIChatMessage(id: UUID().uuidString, role: "system",
            content: "用户确认执行: `\(pending.command)`", timestamp: Date())
        appState.addMessageToCurrentSession(confirmMsg)
        appState.appendAuditEvent(
            category: .aiAction,
            action: "command_confirmation",
            target: pending.command,
            result: .authorized,
            summary: "用户确认 AI 命令执行"
        )
        agentIteration = 0 // Reset iteration counter after manual confirmation
        executeCommand(pending.command, pending: pending) {
            self.agentIteration += 1
            self.continueAgentLoop()
        }
    }

    private func getActiveSSHSessionId() -> String? {
        guard let activeId = appState.activeTabId,
              let tab = appState.tabs.first(where: { $0.id == activeId }) else { return nil }
        return tab.focusedChannelId ?? tab.sessionId
    }

    private func collectAIContext(for sessionContext: ActiveSessionContext) -> String {
        if sessionContext.kind == .database {
            guard let tabId = sessionContext.tabId,
                  let dbContext = appState.databaseAIContexts[tabId] else {
                return "（Database 面板已打开，暂无 SQL 上下文）"
            }
            return """
            当前 Database Tab: \(sessionContext.serverName ?? "Database")
            当前选表: \(dbContext.selectedTable ?? "未选择")
            SQL 编辑器:
            ```sql
            \(dbContext.sqlText)
            ```
            结果摘要: \(dbContext.resultSummary)
            """
        }
        return collectTerminalContext()
    }

    private func collectTerminalContext() -> String {
        guard let activeId = appState.activeTabId,
              let tab = appState.tabs.first(where: { $0.id == activeId }),
              let sid = tab.focusedChannelId ?? tab.sessionId else {
            return "（无活跃终端会话）"
        }

        guard let tv = OrbitBridge.shared.terminalView(for: sid) as? OrbitTerminalView else {
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

    private func buildSystemPrompt(context: String, agentMode: Bool, sessionContext: ActiveSessionContext) -> String {
        if sessionContext.kind == .database {
            return """
            你是一个数据库助手，帮助用户分析 SQL、表结构和查询结果。

            ## 当前数据库上下文
            \(context)

            ## 你的职责
            1. 解释当前 SQL 的意图和风险
            2. 给出可复制到 SQL 编辑器的建议 SQL
            3. 对 UPDATE/DELETE/DROP/ALTER/TRUNCATE 等高风险 SQL 明确提示

            ## 注意
            - 当前版本不能自动执行 SQL
            - 不要使用 execute 代码块
            - 建议 SQL 请使用 ```sql 代码块
            """
        }
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

        ## 授权执行模式
        你已连接到终端，可以使用 ```execute 代码块请求在终端中执行命令并获取输出。
        格式：
        ```execute
        command_here
        ```
        每条回复最多一个 execute 块。只在需要获取系统信息时使用。任何 execute 块都会先展示给用户确认，用户确认前不会执行。
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
    var isStreaming: Bool = false
    @EnvironmentObject var aiState: AIState
    @EnvironmentObject var tabState: TabState
    let appState: AppState

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
                messageText

                if message.role == "system", message.content.contains("建议命令") {
                    HStack(spacing: 4) {
                        Button("插入") {
                            if let cmd = extractSuggestedCommand(from: message.content) {
                                if let activeId = tabState.activeTabId,
                                   let tab = tabState.tabs.first(where: { $0.id == activeId }),
                                   let sid = tab.focusedChannelId ?? tab.sessionId,
                                   let tv = OrbitBridge.shared.terminalView(for: sid) as? OrbitTerminalView {
                                    appState.insertSnippetCommand(cmd, into: tv)
                                    appState.appendAuditEvent(
                                        category: .aiAction,
                                        action: "command_insert",
                                        target: cmd,
                                        result: .succeeded,
                                        summary: "AI 建议命令已插入终端"
                                    )
                                }
                            }
                        }
                        .font(.system(size: 10))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.18))
                        .clipShape(Capsule())
                        .buttonStyle(.plain)

                        Button("运行") {
                            if let cmd = extractSuggestedCommand(from: message.content) {
                                requestSuggestedCommandConfirmation(cmd)
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

    @ViewBuilder
    private var messageText: some View {
        if isStreaming {
            Text(formattedContent)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if message.role == "user" {
            Text(formattedContent)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let md = formattedMarkdown {
            Text(md)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(formattedContent)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func requestSuggestedCommandConfirmation(_ command: String) {
        guard let tabId = tabState.activeTabId else {
            appState.appendAuditEvent(
                category: .aiAction,
                action: "command_confirmation",
                target: command,
                result: .failed,
                summary: "AI 建议命令请求运行失败：无活动 Tab"
            )
            return
        }

        let context = appState.activeSessionContext
        guard context.kind != .database, let sid = context.sessionId else {
            appState.appendAuditEvent(
                category: .aiAction,
                action: "command_confirmation",
                target: command,
                result: .failed,
                summary: "AI 建议命令请求运行失败：无活跃终端会话"
            )
            return
        }

        let riskReason = AppState.CommandSafety.riskReason(command: command)
        aiState.aiPendingConfirmation = PendingAICommand(
            command: command,
            sessionId: sid,
            tabId: tabId,
            contextIdentity: context.identity,
            serverName: context.serverName,
            host: context.host,
            isHighRisk: riskReason != nil,
            riskReason: riskReason
        )
        appState.appendAuditEvent(
            category: .aiAction,
            action: "command_confirmation",
            target: command,
            result: .requested,
            summary: "用户点击运行 AI 建议命令，需要确认"
        )
    }
}

// MARK: - Error Banner

struct AIErrorBanner: View {
    let errorText: String
    @EnvironmentObject var tabState: TabState
    let appState: AppState

    var body: some View {
        Button(action: {
            tabState.activeTabError = nil
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
                    tabState.activeTabError = nil
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
    @EnvironmentObject var aiState: AIState
    @EnvironmentObject var tabState: TabState
    let appState: AppState
    let onSelect: (AISession) -> Void
    let onDismiss: () -> Void

    var sessions: [AISession] {
        let serverId = appState.currentServerId
        return aiState.aiSessions[serverId] ?? []
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
                            if let activeSessionId = aiState.activeAISessionId[appState.activeTabId ?? ""],
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
    let pending: PendingAICommand
    let onConfirm: () -> Void
    let onReject: () -> Void
    @State private var confirmationText: String = ""

    private var canConfirm: Bool {
        !pending.isHighRisk || confirmationText == "EXECUTE"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(pending.isHighRisk ? .red : .yellow)
                Text(pending.isHighRisk ? "高风险命令需要强化确认" : "AI 想执行命令")
                    .font(.system(size: 11, weight: .medium))
            }

            if let serverName = pending.serverName {
                Text([serverName, pending.host].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(pending.command)
                .font(.system(size: 11, design: .monospaced))
                .padding(4)
                .background(Color.black.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            if pending.isHighRisk {
                Text(pending.riskReason ?? "该命令可能修改系统状态或造成破坏性影响")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                TextField("输入 EXECUTE 确认执行", text: $confirmationText)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Button(pending.isHighRisk ? "确认执行高风险命令" : "确认执行") { onConfirm() }
                    .font(.system(size: 10))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((pending.isHighRisk ? Color.red : Color.green).opacity(canConfirm ? 0.22 : 0.08))
                    .clipShape(Capsule())
                    .buttonStyle(.plain)
                    .disabled(!canConfirm)

                Button("拒绝") { onReject() }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background((pending.isHighRisk ? Color.red : Color.yellow).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
