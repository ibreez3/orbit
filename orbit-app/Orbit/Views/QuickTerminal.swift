import SwiftUI
import AppKit

// MARK: - Quick Terminal (dropdown terminal)

class QuickTerminalController: NSObject {
    static let shared = QuickTerminalController()

    private var window: NSPanel?
    private var terminalView: OrbitTerminalView?
    private var localShell: LocalShell?
    private var isVisible = false
    private lazy var outputPump = TerminalOutputPump { [weak self] data, _ in
        guard let tv = self?.terminalView else { return }
        TerminalOutputPump.feed(data, to: tv)
    }

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

        // Font with ligatures
        let fontSize = UserDefaults.standard.double(forKey: "fontSize")
        let fontFamily = UserDefaults.standard.string(forKey: "fontFamily") ?? "Menlo"
        let useLigatures = UserDefaults.standard.bool(forKey: "fontLigatures")
        let size = fontSize > 0 ? fontSize : 14
        var font = NSFont(name: fontFamily, size: size) ?? NSFont(name: "Menlo", size: size)!

        if useLigatures {
            let descriptor = font.fontDescriptor.addingAttributes([
                .featureSettings: [
                    [kCTFontFeatureTypeIdentifierKey: 1,   // kLigaturesType
                     kCTFontFeatureSelectorIdentifierKey: 2], // kCommonLigaturesOnSelector
                    [kCTFontFeatureTypeIdentifierKey: 1,   // kLigaturesType
                     kCTFontFeatureSelectorIdentifierKey: 3], // kRareLigaturesOnSelector
                    [kCTFontFeatureTypeIdentifierKey: 35,  // kContextualAlternatesType
                     kCTFontFeatureSelectorIdentifierKey: 2], // kContextualAlternatesOnSelector
                ]
            ])
            if let ligatureFont = NSFont(descriptor: descriptor, size: size) {
                font = ligatureFont
            }
        }
        tv.font = font

        // Scrollback buffer
        let scrollback = UserDefaults.standard.object(forKey: "scrollbackLines") as? Int ?? 10000
        tv.changeScrollback(scrollback)

        // URL highlighting
        tv.linkReporting = .implicit
        tv.linkHighlightMode = .hover

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
        shell.onData = { [weak self] data in
            self?.outputPump.enqueue(data)
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
