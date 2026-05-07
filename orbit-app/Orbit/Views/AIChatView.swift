import SwiftUI
import SwiftTerm

struct AIChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var service = OpenAIService()
    @State private var inputText: String = ""
    @State private var scrollProxy: ScrollViewProxy? = nil

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
                Spacer()
                Button(action: { appState.clearCurrentSessionMessages() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .disabled(appState.currentMessages.isEmpty)
                .help("清除对话历史")
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
                                }
                                .padding(.vertical, 20)
                                .frame(maxWidth: .infinity)
                            }

                            ForEach(appState.currentMessages) { message in
                                MessageBubble(message: message)
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
                }

                Divider()

                // Input
                HStack(spacing: 8) {
                    TextField("描述问题...", text: $inputText)
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

        let userMsg = AIChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: questionText,
            timestamp: Date()
        )
        appState.addMessageToCurrentSession(userMsg)

        let context = collectTerminalContext()
        let systemPrompt = buildSystemPrompt(context: context)

        service.streamMessage(
            messages: appState.currentMessages,
            systemPrompt: systemPrompt,
            config: appState.aiConfig,
            onToken: { token in
                self.appState.appendToCurrentAssistantMessage(text: token)
            },
            onComplete: { result in
                switch result {
                case .success(let content):
                    // Content already accumulated via onToken; extract command suggestion
                    if !content.isEmpty, let cmd = self.extractCommand(from: content) {
                        let cmdMsg = AIChatMessage(
                            id: UUID().uuidString,
                            role: "system",
                            content: "💡 建议命令: `\(cmd)` — 点击执行或复制到终端",
                            timestamp: Date()
                        )
                        self.appState.addMessageToCurrentSession(cmdMsg)
                    }

                case .failure(let error):
                    let errorMsg = AIChatMessage(
                        id: UUID().uuidString,
                        role: "system",
                        content: "错误: \(error.localizedDescription)",
                        timestamp: Date()
                    )
                    self.appState.addMessageToCurrentSession(errorMsg)
                }
            }
        )
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

    private func buildSystemPrompt(context: String) -> String {
        """
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
                Text(formattedContent)
                    .font(.system(size: 12))
                    .textSelection(.enabled)

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
        // Strip ```command blocks and inline ``` markers for display
        var content = message.content
        // Remove code blocks with language specifier
        let blockPattern = "```[a-z]*\\s*\\n([\\s\\S]*?)\\n```"
        if let regex = try? NSRegularExpression(pattern: blockPattern, options: []) {
            content = regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "$1")
        }
        return content
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
