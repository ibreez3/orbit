import AppKit
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
    private var globalMonitor: Any?

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
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
    }
}
