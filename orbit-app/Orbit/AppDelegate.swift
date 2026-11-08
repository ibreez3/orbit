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
        OrbitBridge.shared.shutdownPool()
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
