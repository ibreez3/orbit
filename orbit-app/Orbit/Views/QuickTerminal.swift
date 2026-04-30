import SwiftUI
import AppKit

// MARK: - Quick Terminal (dropdown terminal)

class QuickTerminalController: NSObject {
    static let shared = QuickTerminalController()

    private var window: NSPanel?
    private var terminalView: OrbitTerminalView?
    private var localShell: LocalShell?
    private var isVisible = false

    private let hotkeyIdentifier = "quickTerminal"

    override init() {
        super.init()
        setupHotkey()
    }

    private func setupHotkey() {
        // Register global hotkey: Ctrl+`
        // We use Carbon API for global hotkey
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        if window == nil {
            createWindow()
        }
        window?.orderFrontRegardless()
        isVisible = true
        terminalView?.window?.makeFirstResponder(terminalView)

        // Focus the window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    private func createWindow() {
        let screen = NSScreen.main!
        let screenFrame = screen.visibleFrame
        let width = min(screenFrame.width - 40, 900)
        let height: CGFloat = 420
        let x = screenFrame.origin.x + (screenFrame.width - width) / 2
        let y = screenFrame.origin.y + screenFrame.height - height - 10

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear

        // Create terminal view
        let tv = OrbitTerminalView()
        tv.frame = NSRect(x: 0, y: 0, width: width, height: height)
        tv.autoresizingMask = [.width, .height]

        // Apply theme
        let themeStr = UserDefaults.standard.string(forKey: "theme") ?? "catppuccinMocha"
        let theme = AppTheme(rawValue: themeStr) ?? .catppuccinMocha
        let tc = ThemeColors.colors(for: theme)
        tv.nativeBackgroundColor = NSColor(red: tc.background.red, green: tc.background.green, blue: tc.background.blue, alpha: 0.95)
        tv.nativeForegroundColor = NSColor(red: tc.foreground.red, green: tc.foreground.green, blue: tc.foreground.blue, alpha: 1)

        // Font
        let fontSize = UserDefaults.standard.double(forKey: "fontSize")
        let fontFamily = UserDefaults.standard.string(forKey: "fontFamily") ?? "Menlo"
        let size = fontSize > 0 ? fontSize : 14
        tv.font = NSFont(name: fontFamily, size: size) ?? NSFont(name: "Menlo", size: size)!

        // URL highlighting
        tv.linkReporting = .implicit
        tv.linkHighlightMode = .hover

        // Metal
        if UserDefaults.standard.bool(forKey: "useMetalRenderer") {
            try? tv.setUseMetal(true)
        }

        // Background blur behind panel
        let blur = NSVisualEffectView()
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.material = .hudWindow
        blur.wantsLayer = true
        blur.frame = tv.bounds
        blur.autoresizingMask = [.width, .height]
        tv.addSubview(blur, positioned: .below, relativeTo: nil)

        panel.contentView = tv
        terminalView = tv

        // Start local shell
        let shell = LocalShell()
        localShell = shell
        shell.onData = { data in
            DispatchQueue.main.async {
                var copy = data
                copy.withUnsafeMutableBytes { buf in
                    if let base = buf.baseAddress {
                        let slice = ArraySlice(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: data.count))
                        tv.feed(byteArray: slice)
                    }
                }
            }
        }
        shell.onClosed = {
            DispatchQueue.main.async {
                tv.feed(text: "\r\n\u{1b}[33m--- 快速终端已退出 ---\u{1b}[0m\r\n")
            }
        }
        shell.start(cols: UInt16(Int(width / (size * 0.6))), rows: UInt16(Int(height / (size * 1.4))))

        self.window = panel
    }
}
