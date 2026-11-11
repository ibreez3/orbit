import SwiftUI
import AppKit
import Combine

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()

    private var windowController: NSWindowController?
    private var hostingController: NSHostingController<AboutView>?
    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        super.init()
    }

    func open() {
        let manager = UpdateManager.shared
        manager.refreshFromUpdater()

        if let window = windowController?.window {
            resizeToFit()
            window.centerOverMainWindow()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: AboutView(updateManager: manager))
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = "关于 Orbit"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.delegate = self
        window.minSize = NSSize(width: 420, height: 320)
        window.setContentSize(NSSize(width: 440, height: 360))

        let wc = NSWindowController(window: window)
        windowController = wc
        hostingController = hosting

        observeStatus(manager)

        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        DispatchQueue.main.async { [weak self] in
            self?.resizeToFit(center: true)
        }
    }

    private func observeStatus(_ manager: UpdateManager) {
        cancellables.removeAll()
        manager.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizeToFit() }
            }
            .store(in: &cancellables)
    }

    private func resizeToFit(center: Bool = false) {
        guard let window = windowController?.window,
              let hosting = hostingController else { return }

        hosting.view.layoutSubtreeIfNeeded()
        let preferred = hosting.preferredContentSize == .zero
            ? hosting.view.fittingSize
            : hosting.preferredContentSize
        guard preferred.width > 0, preferred.height > 0 else { return }

        let width = max(420, min(preferred.width, 560))
        let height = max(320, min(preferred.height, 720))
        let oldCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)

        window.setContentSize(NSSize(width: width, height: height))

        if center {
            window.centerOverMainWindow()
        } else {
            var frame = window.frame
            frame.origin = NSPoint(
                x: oldCenter.x - frame.width / 2,
                y: oldCenter.y - frame.height / 2
            )
            window.setFrame(frame, display: true)
        }
    }
}
