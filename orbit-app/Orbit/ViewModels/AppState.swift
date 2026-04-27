import SwiftUI
import Observation

@Observable
class AppState {
    var servers: [Server] = []
    var credentialGroups: [CredentialGroup] = []
    var tabs: [TabItem] = []
    var activeTabId: String? = nil
    var sidebarCollapsed: Bool = false

    var dialogOpen: Bool = false
    var editingServer: Server? = nil
    var dialogDefaults: ServerInput? = nil

    var cgDialogOpen: Bool = false
    var editingCg: CredentialGroup? = nil

    let bridge = OrbitBridge.shared

    func loadServers() {
        Task {
            do {
                servers = try bridge.listServers()
            } catch {
                print("加载服务器列表失败: \(error)")
            }
        }
    }

    func loadCredentialGroups() {
        Task {
            do {
                credentialGroups = try bridge.listCredentialGroups()
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
                    if let sid = tab.sessionId {
                        bridge.sshDataHandlers.removeValue(forKey: sid)
                        bridge.sshClosedHandlers.removeValue(forKey: sid)
                        try? bridge.disconnectSSH(sessionId: sid)
                    }
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
        let tab = TabItem(id: id, type: type, serverId: server.id, serverName: server.name, title: titles[type] ?? "")
        tabs.append(tab)
        activeTabId = id
    }

    func removeTab(_ id: String) {
        if let tab = tabs.first(where: { $0.id == id }),
           let sid = tab.sessionId {
            bridge.sshDataHandlers.removeValue(forKey: sid)
            bridge.sshClosedHandlers.removeValue(forKey: sid)
            Task { try? bridge.disconnectSSH(sessionId: sid) }
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

    func toggleSidebar() {
        sidebarCollapsed.toggle()
    }
}
