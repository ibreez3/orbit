import SwiftUI
import AppKit
import Carbon.HIToolbox
import SwiftTerm

// MARK: - Quick Terminal (dropdown terminal)

@MainActor
final class QuickTerminalDelegate: NSObject, TerminalViewDelegate {
    weak var controller: QuickTerminalController?

    init(controller: QuickTerminalController) {
        self.controller = controller
    }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        controller?.write(Data(data))
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
#if DEBUG
        (source as? OrbitTerminalView)?.sizeChangedCount += 1
#endif
        controller?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

    func requestOpenLink(source: SwiftTerm.TerminalView, request: TerminalLinkRequest) {
        request.openDefault()
    }

    func bell(source: SwiftTerm.TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

class QuickTerminalController: NSObject {
    static let shared = QuickTerminalController()

    private var window: NSPanel?
    private var terminalView: OrbitTerminalView?
    private var localShell: LocalShell?
    private var isVisible = false
    private lazy var outputPump = TerminalOutputPump { [weak self] data, _ in
        guard let tv = self?.terminalView else { return }
        TerminalOutputPump.feed(data, to: tv)
        let policy = TerminalOutputPolicy(snapshot: tv.terminalInputStateSnapshot(), backlog: 0,
                                          isActiveTab: false, isFocusedPane: false, keywordsEnabled: false)
        tv.setTUIInteractionActive(policy.isTUI)
    }

    private let hotkeyIdentifier = "quickTerminal"
    @MainActor private lazy var inputDelegate = QuickTerminalDelegate(controller: self)
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    override init() {
        super.init()
        setupHotkey()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let hotKeyHandlerRef { RemoveEventHandler(hotKeyHandlerRef) }
    }

    @MainActor func configureTerminalView(_ view: OrbitTerminalView) {
        view.terminalDelegate = inputDelegate
    }

    func write(_ data: Data) {
        localShell?.write(data)
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        localShell?.resize(cols: UInt16(cols), rows: UInt16(rows))
    }

    private func setupHotkey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<QuickTerminalController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async { controller.toggle() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4F524254), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Grave),
            UInt32(controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    @MainActor func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    @MainActor private func show() {
        if window == nil {
            createWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
        terminalView?.window?.makeFirstResponder(terminalView)
    }

    private func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    @MainActor private func createWindow() {
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
        configureTerminalView(tv)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: height)
        tv.autoresizingMask = [.width, .height]

        let themeStr = UserDefaults.standard.string(forKey: "theme") ?? "catppuccinMocha"
        let theme = AppTheme(rawValue: themeStr) ?? .catppuccinMocha
        tv.configureRenderSettings(theme: theme, backgroundAlpha: 0.95)

        panel.contentView = tv
        terminalView = tv

        // Start local shell
        let shell = LocalShell()
        localShell = shell
        let pump = outputPump
        shell.onData = { data in
            pump.enqueue(data)
        }
        shell.onClosed = {
            DispatchQueue.main.async {
                tv.feed(text: "\r\n\u{1b}[33m--- 快速终端已退出 ---\u{1b}[0m\r\n")
            }
        }
        let dimensions = tv.terminalDimensions
        shell.start(cols: UInt16(clamping: max(1, dimensions.cols)), rows: UInt16(clamping: max(1, dimensions.rows)))

        self.window = panel
    }
}
