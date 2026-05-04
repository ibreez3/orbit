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
                            if appState.aiMessages.isEmpty {
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

                            ForEach(appState.aiMessages) { message in
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

                    Button(action: sendMessage) {
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
        .frame(width: 280)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        let userMsg = AIChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: text,
            timestamp: Date()
        )
        appState.addAIMessage(userMsg)
        inputText = ""

        // Collect terminal output as context
        let context = collectTerminalContext()
        let systemPrompt = buildSystemPrompt(context: context)

        service.sendMessage(
            messages: appState.aiMessages,
            systemPrompt: systemPrompt,
            config: appState.aiConfig
        ) { result in
            switch result {
            case .success(let content):
                let assistantMsg = AIChatMessage(
                    id: UUID().uuidString,
                    role: "assistant",
                    content: content,
                    timestamp: Date()
                )
                appState.addAIMessage(assistantMsg)

                // Try to extract a command suggestion
                if let cmd = extractCommand(from: content) {
                    let cmdMsg = AIChatMessage(
                        id: UUID().uuidString,
                        role: "system",
                        content: "💡 建议命令: `\(cmd)` — 点击执行或复制到终端",
                        timestamp: Date()
                    )
                    appState.addAIMessage(cmdMsg)
                }

            case .failure(let error):
                let errorMsg = AIChatMessage(
                    id: UUID().uuidString,
                    role: "system",
                    content: "错误: \(error.localizedDescription)",
                    timestamp: Date()
                )
                appState.addAIMessage(errorMsg)
            }
        }
    }

    private func collectTerminalContext() -> String {
        guard let activeId = appState.activeTabId,
              let tab = appState.tabs.first(where: { $0.id == activeId }),
              (tab.sessionId ?? tab.focusedChannelId) != nil else {
            return "（无活跃终端会话）"
        }
        return "（终端会话已连接）"
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
