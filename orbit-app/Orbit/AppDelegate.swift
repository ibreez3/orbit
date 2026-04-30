import AppKit
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
    private var eventMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register global hotkey for Quick Terminal: Ctrl+`
        // We monitor key events globally
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Ctrl + backtick
            if event.modifierFlags.contains(.control) && event.keyCode == 50 {
                DispatchQueue.main.async {
                    QuickTerminalController.shared.toggle()
                }
            }
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
