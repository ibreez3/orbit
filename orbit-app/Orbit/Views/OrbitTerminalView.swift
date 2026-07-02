import SwiftTerm
import AppKit
import CoreText

private var terminalSettingsObservationContext = 0

struct TerminalSettingsSnapshot: Equatable {
    let fontFamily: String
    let fontSize: CGFloat
    let fontLigatures: Bool
    let cursorStyle: String
    let scrollbackLines: Int
    let backgroundBlur: Bool

    static func current() -> TerminalSettingsSnapshot {
        let defaults = UserDefaults.standard
        let configuredFontFamily = defaults.string(forKey: "fontFamily")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fontSize = defaults.double(forKey: "fontSize")
        return TerminalSettingsSnapshot(
            fontFamily: configuredFontFamily?.isEmpty == false ? configuredFontFamily! : TerminalRenderSettings.defaultFontName,
            fontSize: CGFloat(fontSize > 0 ? fontSize : 14),
            fontLigatures: defaults.bool(forKey: "fontLigatures"),
            cursorStyle: defaults.string(forKey: "cursorStyle") ?? "bar",
            scrollbackLines: defaults.object(forKey: "scrollbackLines") as? Int ?? 10000,
            backgroundBlur: defaults.bool(forKey: "backgroundBlur")
        )
    }
}

enum TerminalRenderSettings {
    static let preferredFontNames = [
        "MesloLGS NF",
        "MesloLGS Nerd Font Mono",
        "JetBrainsMono Nerd Font Mono",
        "Hack Nerd Font Mono",
        "FiraCode Nerd Font Mono",
        "CaskaydiaCove Nerd Font Mono",
        "SauceCodePro Nerd Font Mono",
        "SF Mono",
        "Menlo"
    ]

    static var defaultFontName: String {
        preferredFontNames.first(where: { isFontAvailable($0) }) ?? "Menlo"
    }

    static var configuredFontSize: CGFloat {
        let fontSize = UserDefaults.standard.double(forKey: "fontSize")
        return CGFloat(fontSize > 0 ? fontSize : 14)
    }

    private static var cachedFontKey: String?
    private static var cachedFont: NSFont?

    static func availableTerminalFonts() -> [String] {
        var names = Set<String>()
        for family in NSFontManager.shared.availableFontFamilies {
            let members = NSFontManager.shared.availableMembers(ofFontFamily: family)
            var hasFixedPitchMember = false
            for member in (members ?? []) {
                guard member.count >= 1, let name = member[0] as? String else { continue }
                if NSFont(name: name, size: 14)?.isFixedPitch == true {
                    names.insert(name)
                    hasFixedPitchMember = true
                }
            }
            if hasFixedPitchMember {
                names.insert(family)
            }
        }

        names.insert(defaultFontName)
        let preferred = preferredFontNames.filter { names.contains($0) || isFontAvailable($0) }
        let remaining = names.subtracting(preferred).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        var ordered: [String] = []
        for name in preferred + remaining where !ordered.contains(name) {
            ordered.append(name)
        }
        return ordered
    }

    static func apply(to terminalView: OrbitTerminalView, theme: AppTheme, backgroundAlpha: CGFloat = 1) {
        let snapshot = TerminalSettingsSnapshot.current()
        let tc = ThemeColors.colors(for: theme)
        let colors = tc.ansi.map { SwiftTerm.Color(red: $0.red, green: $0.green, blue: $0.blue) }
        terminalView.installColors(colors)

        terminalView.nativeBackgroundColor = NSColor(
            red: tc.background.red,
            green: tc.background.green,
            blue: tc.background.blue,
            alpha: backgroundAlpha
        )
        terminalView.nativeForegroundColor = NSColor(
            red: tc.foreground.red,
            green: tc.foreground.green,
            blue: tc.foreground.blue,
            alpha: 1
        )

        terminalView.font = makeFont()

        let term = terminalView.getTerminal()
        switch snapshot.cursorStyle {
        case "block":
            term.setCursorStyle(.steadyBlock)
        case "underline":
            term.setCursorStyle(.steadyUnderline)
        default:
            term.setCursorStyle(.steadyBar)
        }

        terminalView.changeScrollback(snapshot.scrollbackLines)
        terminalView.linkReporting = .implicit
        terminalView.linkHighlightMode = .hover
    }

    private static func makeFont() -> NSFont {
        let snapshot = TerminalSettingsSnapshot.current()
        let cacheKey = "\(snapshot.fontFamily)|\(snapshot.fontSize)|\(snapshot.fontLigatures)"
        if cachedFontKey == cacheKey, let cachedFont {
            return cachedFont
        }

        var font = resolveFont(name: snapshot.fontFamily, size: snapshot.fontSize)
            ?? resolveFont(name: defaultFontName, size: snapshot.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: snapshot.fontSize, weight: .regular)

        if snapshot.fontLigatures {
            let descriptor = font.fontDescriptor.addingAttributes([
                .featureSettings: [
                    [kCTFontFeatureTypeIdentifierKey: 1, kCTFontFeatureSelectorIdentifierKey: 2],
                    [kCTFontFeatureTypeIdentifierKey: 1, kCTFontFeatureSelectorIdentifierKey: 3],
                    [kCTFontFeatureTypeIdentifierKey: 35, kCTFontFeatureSelectorIdentifierKey: 2],
                ]
            ])
            if let ligatureFont = NSFont(descriptor: descriptor, size: snapshot.fontSize) {
                font = ligatureFont
            }
        }

        cachedFontKey = cacheKey
        cachedFont = font
        return font
    }

    private static func isFontAvailable(_ name: String) -> Bool {
        resolveFont(name: name, size: 14) != nil
    }

    private static func resolveFont(name: String, size: CGFloat) -> NSFont? {
        if let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFontManager.shared.font(
            withFamily: name,
            traits: .fixedPitchFontMask,
            weight: 5,
            size: size
        ) ?? NSFontManager.shared.font(
            withFamily: name,
            traits: [],
            weight: 5,
            size: size
        )
    }
}

class OrbitTerminalView: SwiftTerm.TerminalView {
    var tabId: String?
    weak var appState: AppState?
    private var renderTheme: AppTheme = .catppuccinMocha
    private var renderBackgroundAlpha: CGFloat = 1
    private var observingSettingsKeys = false
    private var lastSettingsSnapshot: TerminalSettingsSnapshot?
    private static let settingsKeys = [
        "fontFamily",
        "fontSize",
        "fontLigatures",
        "cursorStyle",
        "scrollbackLines",
        "backgroundBlur"
    ]

    // Pending paste text after confirmation
    private var pendingPasteText: String?

    // Background blur
    private var blurView: NSVisualEffectView?

    // MARK: - Blur background

    func setupBlur() {
        guard blurView == nil else { return }
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

    func configureRenderSettings(theme: AppTheme, backgroundAlpha: CGFloat = 1) {
        renderTheme = theme
        renderBackgroundAlpha = backgroundAlpha
        TerminalRenderSettings.apply(to: self, theme: theme, backgroundAlpha: backgroundAlpha)
        updateBlurEnabled(UserDefaults.standard.bool(forKey: "backgroundBlur"))
        lastSettingsSnapshot = TerminalSettingsSnapshot.current()
    }

    // MARK: - Keyboard & Mouse event monitors

    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startSettingsObserver()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self = self,
                      self.window?.firstResponder == self,
                      UserDefaults.standard.bool(forKey: "selectToCopy"),
                      self.selectionActive else { return event }
                self.copy(self)
                return event
            }
        } else {
            stopSettingsObserver()
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            if let m = mouseMonitor { NSEvent.removeMonitor(m) }
            keyMonitor = nil
            mouseMonitor = nil
        }
    }

    deinit {
        stopSettingsObserver()
    }

    private func startSettingsObserver() {
        guard !observingSettingsKeys else { return }
        for key in Self.settingsKeys {
            UserDefaults.standard.addObserver(
                self,
                forKeyPath: key,
                options: [.new],
                context: &terminalSettingsObservationContext
            )
        }
        observingSettingsKeys = true
    }

    private func stopSettingsObserver() {
        guard observingSettingsKeys else { return }
        for key in Self.settingsKeys {
            UserDefaults.standard.removeObserver(
                self,
                forKeyPath: key,
                context: &terminalSettingsObservationContext
            )
        }
        observingSettingsKeys = false
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard context == &terminalSettingsObservationContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        if Thread.isMainThread {
            handleTerminalSettingsChange()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.handleTerminalSettingsChange()
            }
        }
    }

    private func handleTerminalSettingsChange() {
        let snapshot = TerminalSettingsSnapshot.current()
        guard snapshot != lastSettingsSnapshot else { return }
        lastSettingsSnapshot = snapshot
        configureRenderSettings(theme: renderTheme, backgroundAlpha: renderBackgroundAlpha)
        needsDisplay = true
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

    func insertInputText(_ text: String) {
        insertText(text as NSString, replacementRange: NSRange(location: 0, length: 0))
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
        if state.requestActivateTab(tid) {
            state.openTool(.sftp)
        }
    }

    @objc private func reconnectSession(_ sender: Any) {
        guard let tid = tabId, let state = appState else { return }
        state.reconnectTab(tid)
    }

    @objc private func openSnippetPicker(_ sender: Any) {
        NotificationCenter.default.post(name: .openSnippetPicker, object: nil)
    }
}
