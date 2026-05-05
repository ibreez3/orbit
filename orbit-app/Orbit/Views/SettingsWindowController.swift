import SwiftUI
import AppKit

class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var windowController: NSWindowController?
    private weak var appState: AppState?

    private override init() {
        super.init()
    }

    func open(with appState: AppState) {
        self.appState = appState

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
        window.delegate = self

        let wc = NSWindowController(window: window)
        windowController = wc
        wc.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        appState?.saveAIConfig()
    }

    func close() {
        appState?.saveAIConfig()
        windowController?.close()
        windowController = nil
        appState = nil
    }
}
