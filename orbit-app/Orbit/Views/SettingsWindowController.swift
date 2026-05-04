import SwiftUI
import AppKit

class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var windowController: NSWindowController?

    private override init() {
        super.init()
    }

    func open(with appState: AppState) {
        if let wc = windowController, let w = wc.window {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = SettingsView()
            .environmentObject(appState)
            .frame(width: 720, height: 520)

        let hc = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hc)
        window.title = "设置"
        window.setContentSize(NSSize(width: 720, height: 520))
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false

        let wc = NSWindowController(window: window)
        windowController = wc
        wc.showWindow(nil)
    }

    func close() {
        windowController?.close()
        windowController = nil
    }
}
