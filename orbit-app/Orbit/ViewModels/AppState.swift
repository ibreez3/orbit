import SwiftUI

class AppState: ObservableObject {
    @Published var servers: [Server] = []
    @Published var credentialGroups: [CredentialGroup] = []
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: String? = nil
    @Published var spotlightOpen: Bool = false
    @Published var spotlightQuery: String = ""
    @Published var sftpDrawerTabId: String? = nil
    @Published var sftpDrawerHeight: CGFloat = 280
    @Published var theme: AppTheme = .catppuccinMocha

    @Published var dialogOpen: Bool = false
    @Published var editingServer: Server? = nil
    @Published var dialogDefaults: ServerInput? = nil

    @Published var cgDialogOpen: Bool = false
    @Published var editingCg: CredentialGroup? = nil

    @Published var showQuitConfirmation: Bool = false
    private var pendingQuitTabId: String? = nil

    let bridge = OrbitBridge.shared
    let textEditorWC = TextEditorWindowController()

    init() {
        // Load persisted theme
        let savedTheme = UserDefaults.standard.string(forKey: "theme") ?? "catppuccinMocha"
        if let t = AppTheme(rawValue: savedTheme) {
            _theme = Published(initialValue: t)
        }
        // Load themes from files
        ThemeManager.shared.loadThemes()
        // Load servers immediately on init
        loadServers()
        loadCredentialGroups()
    }

    func loadServers() {
        Task {
            do {
                let result = try bridge.listServers()
                await MainActor.run { self.servers = result }
            } catch {
                print("加载服务器列表失败: \(error)")
            }
        }
    }

    func loadCredentialGroups() {
        Task {
            do {
                let result = try bridge.listCredentialGroups()
                await MainActor.run { self.credentialGroups = result }
            } catch {
                print("加载凭据分组失败: \(error)")
            }
        }
    }

    func addServer(_ input: ServerInput) {
        Task {
            do {
                let server = try bridge.addServer(input: input)
                servers.append(server)
            } catch {
                print("添加服务器失败: \(error)")
            }
        }
    }

    func updateServer(id: String, input: ServerInput) {
        Task {
            do {
                let server = try bridge.updateServer(id: id, input: input)
                servers = servers.map { $0.id == id ? server : $0 }
            } catch {
                print("更新服务器失败: \(error)")
            }
        }
    }

    func deleteServer(_ id: String) {
        Task {
            do {
                try bridge.deleteServer(id: id)
                let tabsToRemove = tabs.filter { $0.serverId == id }
                for tab in tabsToRemove {
                    disconnectAllChannels(tab: tab)
                }
                servers.removeAll { $0.id == id }
                tabs.removeAll { $0.serverId == id }
                if let active = activeTabId, !tabs.contains(where: { $0.id == active }) {
                    activeTabId = tabs.last?.id
                }
            } catch {
                print("删除服务器失败: \(error)")
            }
        }
    }

    func addCg(_ input: CredentialGroupInput) {
        Task {
            do {
                let cg = try bridge.addCredentialGroup(input: input)
                credentialGroups.append(cg)
            } catch {
                print("添加凭据分组失败: \(error)")
            }
        }
    }

    func updateCg(id: String, input: CredentialGroupInput) {
        Task {
            do {
                let cg = try bridge.updateCredentialGroup(id: id, input: input)
                credentialGroups = credentialGroups.map { $0.id == id ? cg : $0 }
            } catch {
                print("更新凭据分组失败: \(error)")
            }
        }
    }

    func deleteCg(_ id: String) {
        Task {
            do {
                try bridge.deleteCredentialGroup(id: id)
                credentialGroups.removeAll { $0.id == id }
            } catch {
                print("删除凭据分组失败: \(error)")
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
            .settings: "设置",
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
                print("[Split] spawnChannel failed: \(error)")
                return
            }

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
                updateTabSessionId(tabId, sessionId: sessionId)
            } catch {
                print("连接失败: \(error)")
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
        if sftpDrawerTabId == tabId {
            sftpDrawerTabId = nil
        } else {
            sftpDrawerTabId = tabId
        }
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
}
