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

struct TerminalFontKey: Equatable {
    let family: String
    let size: CGFloat
    let ligatures: Bool

    init(_ snapshot: TerminalSettingsSnapshot) {
        family = snapshot.fontFamily
        size = snapshot.fontSize
        ligatures = snapshot.fontLigatures
    }
}

struct TerminalRenderKey: Equatable {
    let theme: AppTheme
    let backgroundAlpha: CGFloat
    let snapshot: TerminalSettingsSnapshot
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

    static let defaultFontName = preferredFontNames.first(where: { isFontAvailable($0) }) ?? "Menlo"

    /// The settings UI defaults this to ON, so an unset key must mean ON too.
    static var selectToCopyEnabled: Bool {
        UserDefaults.standard.object(forKey: "selectToCopy") as? Bool ?? true
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

    static func apply(to terminalView: OrbitTerminalView, key: TerminalRenderKey, previous: TerminalRenderKey?) {
        let snapshot = key.snapshot
        applyFont(to: terminalView, snapshot: snapshot)
        applyPalette(to: terminalView, theme: key.theme)
        applyNativeColors(to: terminalView, key: key)
        if previous?.snapshot.cursorStyle != snapshot.cursorStyle {
            applyCursorStyle(to: terminalView, style: snapshot.cursorStyle)
        }
        if previous?.snapshot.scrollbackLines != snapshot.scrollbackLines {
            terminalView.changeScrollback(snapshot.scrollbackLines)
        }
        applyLinkConfiguration(to: terminalView)
    }

    private static func applyPalette(to terminalView: OrbitTerminalView, theme: AppTheme) {
        let colors = ThemeColors.colors(for: theme).ansi.map {
            SwiftTerm.Color(red: $0.red, green: $0.green, blue: $0.blue)
        }
        guard terminalView.appliedPalette != colors else { return }
        terminalView.installColors(colors)
        terminalView.appliedPalette = colors
    }

    private static func applyNativeColors(to terminalView: OrbitTerminalView, key: TerminalRenderKey) {
        let tc = ThemeColors.colors(for: key.theme)
        let background = NSColor(
            red: tc.background.red, green: tc.background.green, blue: tc.background.blue,
            alpha: key.backgroundAlpha * (key.snapshot.backgroundBlur ? 0.82 : 1)
        )
        let foreground = NSColor(
            red: tc.foreground.red, green: tc.foreground.green, blue: tc.foreground.blue, alpha: 1
        )
        if terminalView.nativeBackgroundColor != background {
            terminalView.nativeBackgroundColor = background
        }
        if terminalView.nativeForegroundColor != foreground {
            terminalView.nativeForegroundColor = foreground
        }
    }

    static func applyFont(to terminalView: OrbitTerminalView, snapshot: TerminalSettingsSnapshot) {
        let key = TerminalFontKey(snapshot)
        guard terminalView.appliedFontKey != key else {
            terminalView.pendingFontSnapshot = nil
            terminalView.toolTip = nil
            return
        }
        if terminalView.isTUIInteractionActive {
            terminalView.pendingFontSnapshot = snapshot
            terminalView.toolTip = "字体更改将在全屏终端程序退出后生效"
            return
        }
        terminalView.pendingFontSnapshot = nil
        terminalView.toolTip = nil
        terminalView.font = makeFont(snapshot: snapshot)
        terminalView.appliedFontKey = key
    }

    private static func applyCursorStyle(to terminalView: OrbitTerminalView, style: String) {
        switch style {
        case "block": terminalView.setCursorStyle(.steadyBlock)
        case "underline": terminalView.setCursorStyle(.steadyUnderline)
        default: terminalView.setCursorStyle(.steadyBar)
        }
    }

    static func applyLinkConfiguration(to terminalView: OrbitTerminalView) {
        if terminalView.linkReporting != .implicit {
            terminalView.linkReporting = .implicit
        }
        let mode: LinkHighlightMode = terminalView.isTUIInteractionActive ? .hoverWithModifier : .hover
        if terminalView.linkHighlightMode != mode {
            terminalView.linkHighlightMode = mode
        }
    }

    private static func makeFont(snapshot: TerminalSettingsSnapshot) -> NSFont {
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installNerdFontFallback()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installNerdFontFallback()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    private func installNerdFontFallback() {
        guard glyphFallbackProvider == nil,
              NerdFontGlyphFallbackProvider.shared.isAvailable else { return }
        glyphFallbackProvider = NerdFontGlyphFallbackProvider.shared
    }

    /// Owned here (rather than by the coordinator) so the shell survives the
    /// view/coordinator rebuild that happens when a pane is split.
    var localShell: LocalShell?
    private var renderTheme: AppTheme = .catppuccinMocha
    private var renderBackgroundAlpha: CGFloat = 1
    private var observingSettingsKeys = false
    private var lastRenderKey: TerminalRenderKey?
    private var isApplyingRenderSettings = false
    fileprivate var appliedPalette: [SwiftTerm.Color]?
    fileprivate var appliedFontKey: TerminalFontKey?
    fileprivate var pendingFontSnapshot: TerminalSettingsSnapshot?
    private(set) var isTUIInteractionActive = false
    private var metalFailureLogged = false
#if DEBUG
    var keywordInjectionCount = 0
    var errorScanCount = 0
    var sizeChangedCount = 0
#endif
    var resizeDeduplicator = TerminalResizeDeduplicator()
    private static let settingsKeys = [
        "fontFamily",
        "fontSize",
        "fontLigatures",
        "cursorStyle",
        "scrollbackLines",
        "backgroundBlur",
        "theme",
        "terminalUseMetal"
    ]

    // Pending paste text after confirmation
    private var pendingPasteText: String?

    func configureRenderSettings(theme: AppTheme, backgroundAlpha: CGFloat = 1) {
        configureRenderSettings(TerminalRenderKey(
            theme: theme, backgroundAlpha: backgroundAlpha, snapshot: .current()
        ))
    }

    func configureRenderSettings(_ key: TerminalRenderKey) {
        guard !isApplyingRenderSettings, key != lastRenderKey else { return }
        isApplyingRenderSettings = true
        defer { isApplyingRenderSettings = false }
        renderTheme = key.theme
        renderBackgroundAlpha = key.backgroundAlpha
        TerminalRenderSettings.apply(to: self, key: key, previous: lastRenderKey)
        lastRenderKey = key
    }

    /// A new shell/session must not inherit alternate-screen or mouse modes
    /// from a TUI that died without restoring the terminal.
    func resetForNewSession() {
        resetToInitialState()
        lastRenderKey = nil
        appliedPalette = nil
        setTUIInteractionActive(false)
        configureRenderSettings(theme: renderTheme, backgroundAlpha: renderBackgroundAlpha)
        if let pendingFontSnapshot {
            TerminalRenderSettings.applyFont(to: self, snapshot: pendingFontSnapshot)
        }
        requestRedraw()
    }

    // MARK: - Keyboard & Mouse event monitors

    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installNerdFontFallback()
        if window != nil {
            setAccessibilityElement(true)
            setAccessibilityRole(.textArea)
            setAccessibilityLabel("终端")
            setAccessibilityIdentifier("orbitTerminal")
            startSettingsObserver()
            updateMetalRenderer()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self,
                      self.window?.firstResponder == self else { return event }
#if DEBUG
                if ProcessInfo.processInfo.environment["ORBIT_TERMINAL_DIAGNOSTICS"] == "1",
                   event.modifierFlags.intersection([.command, .option, .shift, .control]) == [.command, .option, .shift],
                   event.charactersIgnoringModifiers?.lowercased() == "d" {
                    self.copyDiagnostics()
                    return nil
                }
#endif
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
            stopSettingsObserver()
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            keyMonitor = nil
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
        let theme = UserDefaults.standard.string(forKey: "theme").flatMap(AppTheme.init(rawValue:)) ?? renderTheme
        configureRenderSettings(theme: theme, backgroundAlpha: renderBackgroundAlpha)
        updateMetalRenderer()
    }

    func setTUIInteractionActive(_ active: Bool) {
        guard isTUIInteractionActive != active else { return }
        isTUIInteractionActive = active
        TerminalRenderSettings.applyLinkConfiguration(to: self)
        if !active, let pendingFontSnapshot {
            TerminalRenderSettings.applyFont(to: self, snapshot: pendingFontSnapshot)
        }
    }

#if DEBUG
    private func copyDiagnostics() {
        guard let state = terminalInputStateSnapshot() else { return }
        let snapshot: [String: Any] = [
            "cols": state.dimensions.cols,
            "rows": state.dimensions.rows,
            "isAlternateBuffer": state.isAlternateBuffer,
            "mouseMode": String(describing: state.mouseMode),
            "bracketedPasteMode": state.bracketedPasteMode,
            "linkHighlightMode": String(describing: linkHighlightMode),
            "keywordInjectionCount": keywordInjectionCount,
            "errorScanCount": errorScanCount,
            "sizeChangedCount": sizeChangedCount,
            "isUsingMetalRenderer": isUsingMetalRenderer,
            "isUsingRenderLoop": isUsingRenderLoop,
            "fontSize": font.pointSize,
            "selectionActive": selectionActive,
            "visibleText": contextText()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
#endif

    private func updateMetalRenderer() {
        guard window != nil else { return }
        // Metal stays opt-in until the visual matrix (ligatures, transparency,
        // IME overlay, selection, images, split resize) is accepted.
        let environment = ProcessInfo.processInfo.environment["ORBIT_TERMINAL_METAL"]
        let enabled: Bool
        if let environment {
            enabled = environment == "1"
        } else {
            enabled = UserDefaults.standard.object(forKey: "terminalUseMetal") as? Bool ?? false
        }
        guard enabled != isUsingMetalRenderer, !enabled || !metalFailureLogged else { return }
        do {
            try setUseMetal(enabled)
            requestRedraw()
        } catch {
            if !metalFailureLogged {
                print("[Orbit] Metal unavailable, using CoreGraphics: \(error)")
                metalFailureLogged = true
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if TerminalRenderSettings.selectToCopyEnabled, selectionActive {
            copy(self)
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

    func contextText() -> String {
        let rows = terminalDimensions.rows
        return visibleRowsText(max(0, rows - 100)..<rows).joined(separator: "\n")
    }

    func clearScreenAndScrollback() {
        feed(text: "\u{1b}[2J\u{1b}[H")
        clearScrollback()
        requestRedraw()
    }

    @objc private func clearScreen(_ sender: Any) {
        clearScreenAndScrollback()
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
