import SwiftUI
import AppKit

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()

    private var windowController: NSWindowController?

    private override init() {
        super.init()
    }

    func open() {
        UpdateManager.shared.refreshFromUpdater()

        if let wc = windowController, let window = wc.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = AboutView(updateManager: .shared)
            .frame(minWidth: 420, minHeight: 480)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "关于 Orbit"
        window.setContentSize(NSSize(width: 480, height: 640))
        window.minSize = NSSize(width: 420, height: 480)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.delegate = self

        let wc = NSWindowController(window: window)
        windowController = wc
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
    }
}
