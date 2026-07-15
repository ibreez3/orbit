import AppKit
import Carbon
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    private var globalMonitor: Any?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register global hotkey for Quick Terminal: Ctrl+`
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.control) && event.keyCode == 50 {
                DispatchQueue.main.async {
                    QuickTerminalController.shared.toggle()
                }
            }
        }

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
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        NotificationCenter.default.removeObserver(self)
    }
}
