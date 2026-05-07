import SwiftTerm
import AppKit

class OrbitTerminalView: SwiftTerm.TerminalView {
    var tabId: String?
    weak var appState: AppState?

    // Pending paste text after confirmation
    private var pendingPasteText: String?

    // Background blur
    private var blurView: NSVisualEffectView?

    // MARK: - Blur background

    func setupBlur() {
        guard UserDefaults.standard.bool(forKey: "backgroundBlur") else { return }
        let blur = NSVisualEffectView()
        blur.wantsLayer = true
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.material = .hudWindow
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur, positioned: .below, relativeTo: nil)
        blurView = blur

        // Make terminal background semi-transparent
        nativeBackgroundColor = nativeBackgroundColor.withAlphaComponent(0.85)
    }

    func removeBlur() {
        blurView?.removeFromSuperview()
        blurView = nil
        nativeBackgroundColor = nativeBackgroundColor.withAlphaComponent(1.0)
    }

    func updateBlurEnabled(_ enabled: Bool) {
        if enabled {
            setupBlur()
        } else {
            removeBlur()
        }
    }

    // MARK: - Keyboard shortcuts (Cmd+C / Cmd+A)

    private var localEventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self,
                      self.window?.firstResponder == self else { return event }
                if event.modifierFlags.contains(.command) {
                    let chars = event.charactersIgnoringModifiers
                    if chars == "c", self.selectionActive {
                        self.copy(self)
                        return nil
                    }
                    if chars == "a" {
                        self.perform(#selector(NSResponder.selectAll(_:)), with: nil)
                        return nil
                    }
                }
                return event
            }
        } else {
            if let monitor = localEventMonitor {
                NSEvent.removeMonitor(monitor)
                localEventMonitor = nil
            }
        }
    }

    // MARK: - Right-click context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.isEnabled = selectionActive
        menu.addItem(copyItem)

        menu.addItem(withTitle: "粘贴", action: #selector(paste(_:)), keyEquivalent: "v")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "全选", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(withTitle: "清屏", action: #selector(clearScreen(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "搜索", action: #selector(searchTerminal(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "插入命令片段...", action: #selector(openSnippetPicker(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "打开 SFTP", action: #selector(openSftpDrawer(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "重新连接", action: #selector(reconnectSession(_:)), keyEquivalent: "")

        return menu
    }

    // MARK: - Multi-line paste protection

    override open func paste(_ sender: Any) {
        // If we have confirmed pending text, paste it via super
        if let pending = pendingPasteText {
            pendingPasteText = nil
            super.paste(pending as Any)
            return
        }

        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }

        let lineCount = text.components(separatedBy: .newlines).count
        if lineCount > 3 {
            showPasteConfirmation(lineCount: lineCount)
        } else {
            super.paste(sender)
        }
    }

    private func showPasteConfirmation(lineCount: Int) {
        let alert = NSAlert()
        alert.messageText = "粘贴多行内容"
        alert.informativeText = "即将粘贴 \(lineCount) 行内容到终端，是否继续？"
        alert.addButton(withTitle: "粘贴")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        guard let window = self.window else {
            super.paste(self)
            return
        }

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                super.paste(self)
            }
        }
    }

    // MARK: - Menu actions

    @objc private func clearScreen(_ sender: Any) {
        let term = getTerminal()
        term.buffer.clear()
        setNeedsDisplay(self.bounds)
    }

    @objc private func searchTerminal(_ sender: Any) {
        performFindPanelAction(NSTextFinder.Action.showFindInterface.rawValue)
    }

    @objc private func openSftpDrawer(_ sender: Any) {
        guard let tid = tabId, let state = appState else { return }
        state.toggleSftpDrawer(for: tid)
    }

    @objc private func reconnectSession(_ sender: Any) {
        guard let tid = tabId, let state = appState else { return }
        state.reconnectTab(tid)
    }

    @objc private func openSnippetPicker(_ sender: Any) {
        NotificationCenter.default.post(name: .openSnippetPicker, object: nil)
    }
}
