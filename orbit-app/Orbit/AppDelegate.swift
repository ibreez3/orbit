import AppKit
import Carbon

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        shouldTerminateAfterLastWindowClosed(
            activeAgentSessions: AgentGateway.shared.hasActiveSessions ? 1 : 0
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UpdateManager.shared.isInstallingUpdate {
            return .terminateNow
        }
        guard AgentGateway.shared.hasActiveSessions else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "有 AI 会话正在使用 Orbit"
        alert.informativeText = "退出会终止当前所有 AI 会话、命令和 shell。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = QuickTerminalController.shared

        UpdateManager.shared.startAtLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentGateway.shared.stop()
        OrbitBridge.shared.shutdownPool()
    }

}

func shouldTerminateAfterLastWindowClosed(activeAgentSessions: Int) -> Bool {
    activeAgentSessions == 0
}
