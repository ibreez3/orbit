import SwiftUI

class AppState: ObservableObject {
    @Published var servers: [Server] = []
    @Published var credentialGroups: [CredentialGroup] = []
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: String? = nil
    @Published var spotlightOpen: Bool = false
    @Published var spotlightQuery: String = ""
    @Published var theme: AppTheme = .catppuccinMocha
    let sftpDrawer = SftpDrawerState()

    @Published var dialogOpen: Bool = false
    @Published var editingServer: Server? = nil
    @Published var dialogDefaults: ServerInput? = nil

    @Published var cgDialogOpen: Bool = false
    @Published var editingCg: CredentialGroup? = nil

    @Published var showQuitConfirmation: Bool = false
    private var pendingQuitTabId: String? = nil

    @Published var alertMessage: String? = nil
    @Published var alertTitle: String = ""

    // Command snippets
    @Published var snippets: [CommandSnippet] = []
    @Published var snippetEditorOpen: Bool = false
    @Published var editingSnippet: CommandSnippet? = nil

    // Keyword highlighting
    @Published var keywordHighlights: [KeywordHighlight] = KeywordHighlight.defaults

    // AI Assistant
    @Published var aiConfig: AIConfig = .defaults
    @Published var aiMessages: [AIChatMessage] = []
    @Published var aiPanelOpen: Bool = false
    @Published var aiLoading: Bool = false
    @Published var activeTabError: String? = nil

    var showAlert: Binding<Bool> {
        Binding(get: { self.alertMessage != nil }, set: { if !$0 { self.alertMessage = nil } })
    }

    let bridge = OrbitBridge.shared
    let textEditorWC = TextEditorWindowController()

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
        loadAIMessages()
    }

    func loadServers() {
        Task {
            do {
                let result = try bridge.listServers()
                await MainActor.run { self.servers = result }
            } catch {
                await MainActor.run {
                    alertTitle = "加载失败"
                    alertMessage = "无法加载服务器列表: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadCredentialGroups() {
        Task {
            do {
                let result = try bridge.listCredentialGroups()
                await MainActor.run { self.credentialGroups = result }
            } catch {
                await MainActor.run {
                    alertTitle = "加载失败"
                    alertMessage = "无法加载凭据分组: \(error.localizedDescription)"
                }
            }
        }
    }

    func addServer(_ input: ServerInput) {
        Task {
            do {
                let server = try bridge.addServer(input: input)
                await MainActor.run { servers.append(server) }
            } catch {
                await MainActor.run {
                    alertTitle = "添加失败"
                    alertMessage = "无法添加服务器: \(error.localizedDescription)"
                }
            }
        }
    }

    func updateServer(id: String, input: ServerInput) {
        Task {
            do {
                let server = try bridge.updateServer(id: id, input: input)
                await MainActor.run { servers = servers.map { $0.id == id ? server : $0 } }
            } catch {
                await MainActor.run {
                    alertTitle = "更新失败"
                    alertMessage = "无法更新服务器: \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteServer(_ id: String) {
        Task {
            do {
                try bridge.deleteServer(id: id)
                await MainActor.run {
                    let tabsToRemove = tabs.filter { $0.serverId == id }
                    for tab in tabsToRemove {
                        disconnectAllChannels(tab: tab)
                    }
                    servers.removeAll { $0.id == id }
                    tabs.removeAll { $0.serverId == id }
                    if let active = activeTabId, !tabs.contains(where: { $0.id == active }) {
                        activeTabId = tabs.last?.id
                    }
                }
            } catch {
                await MainActor.run {
                    alertTitle = "删除失败"
                    alertMessage = "无法删除服务器: \(error.localizedDescription)"
                }
            }
        }
    }

    func addCg(_ input: CredentialGroupInput) {
        Task {
            do {
                let cg = try bridge.addCredentialGroup(input: input)
                await MainActor.run { credentialGroups.append(cg) }
            } catch {
                await MainActor.run {
                    alertTitle = "添加失败"
                    alertMessage = "无法添加凭据分组: \(error.localizedDescription)"
                }
            }
        }
    }

    func updateCg(id: String, input: CredentialGroupInput) {
        Task {
            do {
                let cg = try bridge.updateCredentialGroup(id: id, input: input)
                await MainActor.run { credentialGroups = credentialGroups.map { $0.id == id ? cg : $0 } }
            } catch {
                await MainActor.run {
                    alertTitle = "更新失败"
                    alertMessage = "无法更新凭据分组: \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteCg(_ id: String) {
        Task {
            do {
                try bridge.deleteCredentialGroup(id: id)
                await MainActor.run { credentialGroups.removeAll { $0.id == id } }
            } catch {
                await MainActor.run {
                    alertTitle = "删除失败"
                    alertMessage = "无法删除凭据分组: \(error.localizedDescription)"
                }
            }
        }
    }

    func addLocalTerminalTab() {
        let id = "local-\(Int(Date().timeIntervalSince1970 * 1000))"
        let tab = TabItem(id: id, type: .terminal, serverId: "local", serverName: "本地", title: "本地终端")
        tabs.append(tab)
        activeTabId = id
    }

    func addTab(server: Server, type: TabType) {
        if type == .monitor {
            if let existing = tabs.first(where: { $0.type == .monitor && $0.serverId == server.id }) {
                activeTabId = existing.id
                return
            }
        }
        let id = "\(type.rawValue)-\(server.id)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let titles: [TabType: String] = [
            .terminal: "SSH: \(server.name)",
            .sftp: "SFTP: \(server.name)",
            .monitor: "Monitor: \(server.name)",
        ]
        var tab = TabItem(id: id, type: type, serverId: server.id, serverName: server.name, title: titles[type] ?? "")
        if type == .terminal {
            tab.paneTree = nil
        }
        tabs.append(tab)
        activeTabId = id
    }

    func splitCurrentPane(direction: SplitDirection) {
        guard let active = activeTabId,
              let tabIdx = tabs.firstIndex(where: { $0.id == active }),
              tabs[tabIdx].type == .terminal else { return }

        let tab = tabs[tabIdx]
        let existingChannelId: String
        if let focused = tab.focusedChannelId {
            existingChannelId = focused
        } else if let sid = tab.sessionId {
            existingChannelId = sid
        } else {
            return
        }

        let tabId = tab.id
        Task {
            let newChannelId: String
            do {
                newChannelId = try bridge.spawnChannel(existingSessionId: existingChannelId)
            } catch {
                await MainActor.run {
                    alertTitle = "分屏失败"
                    alertMessage = "无法创建新通道: \(error.localizedDescription)"
                }
                return
            }

            await MainActor.run {
                guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
                let newSplitId = UUID().uuidString
                let newLeaf = PaneNode.leaf(channelId: newChannelId)

                if let tree = tabs[idx].paneTree {
                    tabs[idx].paneTree = tree.replacingLeaf(channelId: existingChannelId, with:
                        .split(id: newSplitId, direction: direction, ratio: 0.5,
                               first: .leaf(channelId: existingChannelId), second: newLeaf))
                } else {
                    tabs[idx].paneTree = .split(id: newSplitId, direction: direction, ratio: 0.5,
                                                 first: .leaf(channelId: existingChannelId), second: newLeaf)
                }
                tabs[idx].focusedChannelId = newChannelId
            }

            // Focus the new terminal after SwiftUI creates it
            let cid = newChannelId
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if let tv = OrbitBridge.shared.terminalViewCache[cid] as? OrbitTerminalView {
                    tv.window?.makeFirstResponder(tv)
                }
            }
        }
    }

    func closeCurrentPane() {
        guard let active = activeTabId,
              let tabIdx = tabs.firstIndex(where: { $0.id == active }) else { return }

        let tab = tabs[tabIdx]
        guard let tree = tab.paneTree,
              let focused = tab.focusedChannelId ?? tab.sessionId else {
            removeTab(active)
            return
        }

        bridge.sshDataHandlers.removeValue(forKey: focused)
        bridge.sshClosedHandlers.removeValue(forKey: focused)
        bridge.terminalViewCache.removeValue(forKey: focused)
        Task { try? bridge.disconnectSSH(sessionId: focused) }

        if let newTree = tree.removing(channelId: focused) {
            if case .leaf(let remaining) = newTree {
                tabs[tabIdx].paneTree = nil
                tabs[tabIdx].focusedChannelId = nil
                if tabs[tabIdx].sessionId == focused {
                    tabs[tabIdx].sessionId = remaining
                }
            } else {
                tabs[tabIdx].paneTree = newTree
                tabs[tabIdx].focusedChannelId = newTree.channelIds.first
                if tabs[tabIdx].sessionId == focused {
                    tabs[tabIdx].sessionId = newTree.channelIds.first
                }
            }
        } else {
            removeTab(active)
        }
    }

    func navigatePane(forward: Bool) {
        guard let active = activeTabId,
              let tabIdx = tabs.firstIndex(where: { $0.id == active }),
              let tree = tabs[tabIdx].paneTree,
              let focused = tabs[tabIdx].focusedChannelId ?? tabs[tabIdx].sessionId,
              let next = tree.findAdjacent(channelId: focused, forward: forward) else { return }
        tabs[tabIdx].focusedChannelId = next
        if let tv = OrbitBridge.shared.terminalViewCache[next] as? OrbitTerminalView {
            tv.window?.makeFirstResponder(tv)
        }
    }

    func resizePane(grow: Bool) {
        guard let active = activeTabId,
              let tabIdx = tabs.firstIndex(where: { $0.id == active }),
              let tree = tabs[tabIdx].paneTree,
              let focused = tabs[tabIdx].focusedChannelId ?? tabs[tabIdx].sessionId else { return }
        let delta: Double = grow ? 0.05 : -0.05
        tabs[tabIdx].paneTree = tree.adjusting(channelId: focused, delta: delta)
    }

    func updatePaneRatio(tabId: String, splitId: String, newRatio: Double) {
        guard let tabIdx = tabs.firstIndex(where: { $0.id == tabId }),
              let tree = tabs[tabIdx].paneTree else { return }
        tabs[tabIdx].paneTree = tree.updateRatio(splitId: splitId, newRatio: newRatio)
    }

    private func disconnectAllChannels(tab: TabItem) {
        let channelIds: [String]
        if let tree = tab.paneTree {
            channelIds = tree.channelIds
        } else if let sid = tab.sessionId {
            channelIds = [sid]
        } else {
            channelIds = []
        }
        for channelId in channelIds {
            bridge.sshDataHandlers.removeValue(forKey: channelId)
            bridge.sshClosedHandlers.removeValue(forKey: channelId)
            bridge.terminalViewCache.removeValue(forKey: channelId)
            Task { try? bridge.disconnectSSH(sessionId: channelId) }
        }
    }

    func removeTab(_ id: String) {
        performRemoveTab(id)
    }

    func confirmQuit() {
        if let tabId = pendingQuitTabId {
            performRemoveTab(tabId)
        }
        pendingQuitTabId = nil
        showQuitConfirmation = false
        NSApp.terminate(nil)
    }

    func cancelQuit() {
        pendingQuitTabId = nil
        showQuitConfirmation = false
    }

    private func performRemoveTab(_ id: String) {
        if let tab = tabs.first(where: { $0.id == id }) {
            disconnectAllChannels(tab: tab)
        }
        tabs.removeAll { $0.id == id }
        if activeTabId == id {
            let idx = tabs.firstIndex(where: { $0.id == id }) ?? 0
            activeTabId = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id
        }
    }

    func updateTabSessionId(_ tabId: String, sessionId: String) {
        if let idx = tabs.firstIndex(where: { $0.id == tabId }) {
            tabs[idx].sessionId = sessionId
            if tabs[idx].focusedChannelId == nil {
                tabs[idx].focusedChannelId = sessionId
            }
        }
    }

    func connectSSH(tabId: String, serverId: String) {
        Task {
            do {
                let sessionId = try bridge.connectSSH(serverId: serverId)
                await MainActor.run { updateTabSessionId(tabId, sessionId: sessionId) }
            } catch {
                await MainActor.run {
                    alertTitle = "连接失败"
                    alertMessage = "\(error.localizedDescription)"
                }
            }
        }
    }

    func openDialog(server: Server? = nil, defaults: ServerInput? = nil) {
        editingServer = server
        dialogDefaults = defaults
        dialogOpen = true
    }

    func closeDialog() {
        dialogOpen = false
        editingServer = nil
        dialogDefaults = nil
    }

    func openCgDialog(_ cg: CredentialGroup? = nil) {
        editingCg = cg
        cgDialogOpen = true
    }

    func closeCgDialog() {
        cgDialogOpen = false
        editingCg = nil
    }

    func handleChannelClosed(channelId: String) {
        guard let tabIdx = tabs.firstIndex(where: { tab in
            if let tree = tab.paneTree {
                return tree.contains(channelId)
            }
            return tab.sessionId == channelId
        }) else { return }

        let tab = tabs[tabIdx]

        // Clean up handlers and disconnect the dead channel
        bridge.sshDataHandlers.removeValue(forKey: channelId)
        bridge.sshClosedHandlers.removeValue(forKey: channelId)
        bridge.terminalViewCache.removeValue(forKey: channelId)
        Task { try? bridge.disconnectSSH(sessionId: channelId) }

        if let tree = tab.paneTree {
            // Split pane: remove this leaf from the tree
            if let newTree = tree.removing(channelId: channelId) {
                if case .leaf(let remaining) = newTree {
                    tabs[tabIdx].paneTree = nil
                    tabs[tabIdx].focusedChannelId = nil
                    if tabs[tabIdx].sessionId == channelId {
                        tabs[tabIdx].sessionId = remaining
                    }
                } else {
                    tabs[tabIdx].paneTree = newTree
                    tabs[tabIdx].focusedChannelId = tab.focusedChannelId == channelId
                        ? newTree.channelIds.first
                        : tab.focusedChannelId
                    if tabs[tabIdx].sessionId == channelId {
                        tabs[tabIdx].sessionId = newTree.channelIds.first
                    }
                }
            } else {
                // All panes closed
                removeTab(tab.id)
            }
        } else {
            // Single pane: close the whole tab
            removeTab(tab.id)
        }
    }

    func openSpotlight() {
        spotlightQuery = ""
        spotlightOpen = true
    }

    func closeSpotlight() {
        spotlightOpen = false
        spotlightQuery = ""
    }

    func toggleSftpDrawer(for tabId: String) {
        sftpDrawer.toggle(for: tabId)
    }

    func setTheme(_ newTheme: AppTheme) {
        theme = newTheme
        UserDefaults.standard.set(newTheme.rawValue, forKey: "theme")
    }

    func reconnectTab(_ tabId: String) {
        guard let tabIdx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[tabIdx]
        guard tab.type == .terminal else { return }

        // Clear old session state
        if let oldSid = tab.sessionId {
            bridge.sshDataHandlers.removeValue(forKey: oldSid)
            bridge.sshClosedHandlers.removeValue(forKey: oldSid)
            bridge.terminalViewCache.removeValue(forKey: oldSid)
        }
        tabs[tabIdx].sessionId = nil
        tabs[tabIdx].focusedChannelId = nil
        tabs[tabIdx].paneTree = nil

        // Reconnect
        connectSSH(tabId: tabId, serverId: tab.serverId)
    }

    // MARK: - Command Snippets

    func loadSnippets() {
        guard let data = UserDefaults.standard.data(forKey: "commandSnippets") else { return }
        do {
            snippets = try JSONDecoder().decode([CommandSnippet].self, from: data)
        } catch {
            print("[Orbit] Failed to load snippets: \(error)")
        }
    }

    func saveSnippets() {
        do {
            let data = try JSONEncoder().encode(snippets)
            UserDefaults.standard.set(data, forKey: "commandSnippets")
        } catch {
            print("[Orbit] Failed to save snippets: \(error)")
        }
    }

    func addSnippet(_ input: CommandSnippetInput) {
        let id = "snip-\(Int(Date().timeIntervalSince1970 * 1000))"
        let now = Date()
        let snippet = CommandSnippet(
            id: id, name: input.name, command: input.command,
            description: input.description, tags: input.tags,
            serverId: input.serverId, createdAt: now, updatedAt: now
        )
        snippets.append(snippet)
        saveSnippets()
    }

    func updateSnippet(id: String, input: CommandSnippetInput) {
        if let idx = snippets.firstIndex(where: { $0.id == id }) {
            let now = Date()
            let updated = CommandSnippet(
                id: id, name: input.name, command: input.command,
                description: input.description, tags: input.tags,
                serverId: input.serverId, createdAt: snippets[idx].createdAt, updatedAt: now
            )
            snippets[idx] = updated
            saveSnippets()
        }
    }

    func deleteSnippet(_ id: String) {
        snippets.removeAll { $0.id == id }
        saveSnippets()
    }

    func openSnippetEditor(snippet: CommandSnippet? = nil) {
        editingSnippet = snippet
        snippetEditorOpen = true
    }

    func closeSnippetEditor() {
        snippetEditorOpen = false
        editingSnippet = nil
    }

    func insertSnippetCommand(_ command: String, into terminalView: OrbitTerminalView?) {
        guard let tv = terminalView else { return }
        var arr = Array(command.utf8)
        tv.feed(byteArray: ArraySlice(arr))
    }

    // MARK: - Keyword Highlighting

    func loadKeywords() {
        guard let data = UserDefaults.standard.data(forKey: "keywordHighlights") else { return }
        do {
            keywordHighlights = try JSONDecoder().decode([KeywordHighlight].self, from: data)
        } catch {
            print("[Orbit] Failed to load keywords: \(error)")
        }
    }

    func saveKeywords() {
        do {
            let data = try JSONEncoder().encode(keywordHighlights)
            UserDefaults.standard.set(data, forKey: "keywordHighlights")
        } catch {
            print("[Orbit] Failed to save keywords: \(error)")
        }
    }

    func addKeyword(pattern: String, colorHex: String) {
        let id = "kw-\(Int(Date().timeIntervalSince1970 * 1000))"
        keywordHighlights.append(KeywordHighlight(id: id, pattern: pattern, colorHex: colorHex, enabled: true))
        saveKeywords()
    }

    func updateKeyword(id: String, pattern: String, colorHex: String, enabled: Bool) {
        if let idx = keywordHighlights.firstIndex(where: { $0.id == id }) {
            keywordHighlights[idx] = KeywordHighlight(id: id, pattern: pattern, colorHex: colorHex, enabled: enabled)
            saveKeywords()
        }
    }

    func deleteKeyword(_ id: String) {
        keywordHighlights.removeAll { $0.id == id }
        saveKeywords()
    }

    // MARK: - AI Configuration

    func loadAIConfig() {
        guard let data = UserDefaults.standard.data(forKey: "aiConfig") else { return }
        do {
            aiConfig = try JSONDecoder().decode(AIConfig.self, from: data)
        } catch {
            print("[Orbit] Failed to load AI config: \(error)")
        }
    }

    func saveAIConfig() {
        do {
            let data = try JSONEncoder().encode(aiConfig)
            UserDefaults.standard.set(data, forKey: "aiConfig")
        } catch {
            print("[Orbit] Failed to save AI config: \(error)")
        }
    }

    func saveAIMessages() {
        let toSave = Array(aiMessages.suffix(50))
        do {
            let data = try JSONEncoder().encode(toSave)
            UserDefaults.standard.set(data, forKey: "aiMessages")
        } catch {
            print("[Orbit] Failed to save AI messages: \(error)")
        }
    }

    func loadAIMessages() {
        guard let data = UserDefaults.standard.data(forKey: "aiMessages") else { return }
        do {
            aiMessages = try JSONDecoder().decode([AIChatMessage].self, from: data)
        } catch {
            print("[Orbit] Failed to load AI messages: \(error)")
        }
    }

    func addAIMessage(_ message: AIChatMessage) {
        aiMessages.append(message)
        saveAIMessages()
    }

    func appendToLastAssistantMessage(text: String) {
        guard var last = aiMessages.last, last.role == "assistant" else {
            let msg = AIChatMessage(id: UUID().uuidString, role: "assistant", content: text, timestamp: Date())
            aiMessages.append(msg)
            return
        }
        last.content += text
        aiMessages[aiMessages.count - 1] = last
    }

    func clearAIMessages() {
        aiMessages.removeAll()
        saveAIMessages()
    }

    func toggleAIPanel() {
        aiPanelOpen.toggle()
    }

    func submitAIQuestion(_ question: String) {
        let userMsg = AIChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: question,
            timestamp: Date()
        )
        aiMessages.append(userMsg)
        if !aiPanelOpen {
            aiPanelOpen = true
        }
    }

    // MARK: - Batch Execution

    func sendToMultipleServers(command: String, serverIds: [String]) {
        for serverId in serverIds {
            Task {
                do {
                    let sessionId = try bridge.connectSSH(serverId: serverId)
                    try bridge.writeSSH(sessionId: sessionId, data: Data((command + "\r").utf8))
                } catch {
                    print("[Orbit] Batch exec to \(serverId) failed: \(error)")
                }
            }
        }
    }
}
