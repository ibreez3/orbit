import AppKit
import Carbon
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        shouldTerminateAfterLastWindowClosed(
            activeAgentSessions: AgentGateway.shared.hasActiveSessions ? 1 : 0
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkForUpdates),
            name: .checkForUpdates,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentGateway.shared.stop()
        OrbitBridge.shared.shutdownPool()
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

func shouldTerminateAfterLastWindowClosed(activeAgentSessions: Int) -> Bool {
    activeAgentSessions == 0
}
