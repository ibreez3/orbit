import SwiftUI
import SwiftTerm
import AppKit
import CoreText

// MARK: - Keyword Injection

enum KeywordInjector {
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    static func highlight(_ data: Data, keywords: [KeywordHighlight]) -> Data {
        let enabled = keywords.filter { $0.enabled }
        guard !enabled.isEmpty else { return data }
        guard let str = String(data: data, encoding: .utf8) else { return data }

        var result = str
        for kw in enabled {
            let nsPattern = kw.pattern as NSString
            let regex: NSRegularExpression
            if let cached = regexCache.object(forKey: nsPattern) {
                regex = cached
            } else if let compiled = try? NSRegularExpression(pattern: kw.pattern, options: [.caseInsensitive]) {
                regexCache.setObject(compiled, forKey: nsPattern)
                regex = compiled
            } else {
                continue
            }

            let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let ansiCode = hexToAnsi(kw.colorHex)
                let replacement = "\u{1b}[\(ansiCode)m\(result[range])\u{1b}[0m"
                result.replaceSubrange(range, with: replacement)
            }
        }
        return Data(result.utf8)
    }

    static func clearRegexCache() {
        regexCache.removeAllObjects()
    }

    private static func hexToAnsi(_ hex: String) -> String {
        var hexStr = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hexStr.count == 6,
              let r = Int(hexStr.prefix(2), radix: 16),
              let g = Int(hexStr.dropFirst(2).prefix(2), radix: 16),
              let b = Int(hexStr.suffix(2), radix: 16) else { return "33" }
        let rc = r * 5 / 255
        let gc = g * 5 / 255
        let bc = b * 5 / 255
        let colorIdx = 16 + 36 * rc + 6 * gc + bc
        return "38;5;\(colorIdx)"
    }
}

struct TerminalView: NSViewRepresentable {
    let channelId: String?
    let serverId: String
    let tabId: String
    @EnvironmentObject var appState: AppState

    private static func applySettings(_ tv: OrbitTerminalView, theme: AppTheme) {
        let tc = ThemeColors.colors(for: theme)
        let colors = tc.ansi.map { SwiftTerm.Color(red: $0.red, green: $0.green, blue: $0.blue) }
        tv.installColors(colors)

        let bgColor = NSColor(red: tc.background.red, green: tc.background.green, blue: tc.background.blue, alpha: 1)
        tv.nativeBackgroundColor = bgColor
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
                    // Common ligatures (liga): fi, fl, ff, ffi, ffl
                    [kCTFontFeatureTypeIdentifierKey: 1,   // kLigaturesType
                     kCTFontFeatureSelectorIdentifierKey: 2], // kCommonLigaturesOnSelector
                    // Discretionary ligatures (dlig): font-specific decorative ligatures
                    [kCTFontFeatureTypeIdentifierKey: 1,   // kLigaturesType
                     kCTFontFeatureSelectorIdentifierKey: 3], // kRareLigaturesOnSelector
                    // Contextual alternates (calt): -> => != === etc.
                    [kCTFontFeatureTypeIdentifierKey: 35,  // kContextualAlternatesType
                     kCTFontFeatureSelectorIdentifierKey: 2], // kContextualAlternatesOnSelector
                ]
            ])
            if let ligatureFont = NSFont(descriptor: descriptor, size: size) {
                font = ligatureFont
            }
        }
        tv.font = font

        // Cursor style
        let cursorStyle = UserDefaults.standard.string(forKey: "cursorStyle") ?? "bar"
        if let term = tv.getTerminal() as? Terminal {
            switch cursorStyle {
            case "block":
                term.setCursorStyle(.steadyBlock)
            case "underline":
                term.setCursorStyle(.steadyUnderline)
            default:
                term.setCursorStyle(.steadyBar)
            }
        }

        // Scrollback buffer limit (default 10000 lines, configurable)
        let scrollback = UserDefaults.standard.object(forKey: "scrollbackLines") as? Int ?? 10000
        tv.changeScrollback(scrollback)

        // URL hover highlighting — always show underline on hover (no modifier needed)
        tv.linkReporting = .implicit
        tv.linkHighlightMode = .hover
    }

    func makeNSView(context: Context) -> OrbitTerminalView {
        // Reuse cached terminal view if available (preserves buffer on pane tree changes)
        if let cid = channelId, let cached = OrbitBridge.shared.terminalViewCache[cid] as? OrbitTerminalView {
            context.coordinator.sessionId = cid
            context.coordinator.terminalView = cached
            cached.terminalDelegate = context.coordinator
            context.coordinator.registerHandlers()
            Self.applySettings(cached, theme: appState.theme)
            cached.updateBlurEnabled(UserDefaults.standard.bool(forKey: "backgroundBlur"))
            if let term = cached.getTerminal() as? Terminal {
                do { try OrbitBridge.shared.resizeSSH(sessionId: cid, cols: UInt32(term.cols), rows: UInt32(term.rows)) } catch { print("[Orbit] resizeSSH(cached) failed: \(error)") }
            }
            return cached
        }

        let tv = OrbitTerminalView()
        tv.tabId = tabId
        tv.appState = appState
        Self.applySettings(tv, theme: appState.theme)
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv

        // Background blur
        tv.updateBlurEnabled(UserDefaults.standard.bool(forKey: "backgroundBlur"))

        if let cid = channelId {
            context.coordinator.sessionId = cid
            OrbitBridge.shared.terminalViewCache[cid] = tv
            context.coordinator.registerHandlers()
            if let term = tv.getTerminal() as? Terminal {
                do { try OrbitBridge.shared.resizeSSH(sessionId: cid, cols: UInt32(term.cols), rows: UInt32(term.rows)) } catch { print("[Orbit] resizeSSH(cached) failed: \(error)") }
            }
        } else {
            context.coordinator.connect()
        }

        return tv
    }

    func updateNSView(_ nsView: OrbitTerminalView, context: Context) {
        if context.coordinator.sessionId == nil, let cid = channelId {
            context.coordinator.sessionId = cid
            context.coordinator.registerHandlers()
        }
        nsView.tabId = tabId
        nsView.appState = appState
        Self.applySettings(nsView, theme: appState.theme)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(channelId: channelId, serverId: serverId, tabId: tabId, appState: appState)
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        let channelId: String?
        let serverId: String
        let tabId: String
        let appState: AppState
        weak var terminalView: SwiftTerm.TerminalView?
        var sessionId: String?
        private var alive = true
        private var localShell: LocalShell?

        // Frame-batched feed: coalesce multiple data chunks into one feed() per run loop
        private var _batchLock = os_unfair_lock()
        private var _pending = Data()
        private var _pendingCount = 0

        // AI ! prefix question buffer
        private var _aiBuffer = ""
        private var _aiMode = false

        // Error detection throttling
        private var _lastErrorScanTime: Date = .distantPast
        private var _lastErrorSetTime: Date = .distantPast

        var isLocal: Bool { serverId == "local" }

        init(channelId: String?, serverId: String, tabId: String, appState: AppState) {
            self.channelId = channelId
            self.serverId = serverId
            self.tabId = tabId
            self.appState = appState
        }

        deinit {
            alive = false
            localShell = nil
        }

        private func enqueueData(_ data: Data) {
            let first: Bool
            os_unfair_lock_lock(&_batchLock)
            _pending.append(data)
            _pendingCount += 1
            first = (_pendingCount == 1)
            os_unfair_lock_unlock(&_batchLock)
            if first {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.alive, let tv = self.terminalView else { return }
                    os_unfair_lock_lock(&self._batchLock)
                    let batch = self._pending
                    self._pending = Data()
                    self._pendingCount = 0
                    os_unfair_lock_unlock(&self._batchLock)
                    if batch.isEmpty { return }
                    // Apply keyword highlighting — inject ANSI color codes
                    let highlighted = KeywordInjector.highlight(batch, keywords: self.appState.keywordHighlights)

                    // Scan for error patterns (throttled)
                    self.scanForErrors(in: highlighted)

                    let len = highlighted.count
                    var copy = highlighted
                    copy.withUnsafeMutableBytes { buf in
                        if let base = buf.baseAddress {
                            let slice = ArraySlice(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: len))
                            tv.feed(byteArray: slice)
                        }
                    }
                }
            }
        }

        private func scanForErrors(in data: Data) {
            let now = Date()
            guard now.timeIntervalSince(_lastErrorScanTime) >= 2.0 else { return }
            _lastErrorScanTime = now

            guard now.timeIntervalSince(_lastErrorSetTime) >= 3.0 else { return }

            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }

            let patterns: [(String, String)] = [
                ("command not found", "命令未找到"),
                ("Permission denied", "权限被拒绝"),
                ("FATAL", "严重错误"),
                ("fatal:", "严重错误"),
                ("panic:", "程序恐慌"),
                ("Segmentation fault", "段错误"),
                ("Aborted", "进程中止"),
                ("Killed", "进程被杀死"),
                ("Connection refused", "连接被拒绝"),
                ("No route to host", "无法到达主机"),
                ("Could not resolve host", "无法解析主机名"),
                ("error:", "错误"),
                ("Error:", "错误"),
            ]

            for (pattern, _) in patterns {
                if text.range(of: pattern, options: .caseInsensitive) != nil {
                    // Extract surrounding context
                    let lines = text.components(separatedBy: "\n")
                    var contextLines: [String] = []
                    for (i, line) in lines.enumerated() {
                        if line.range(of: pattern, options: .caseInsensitive) != nil {
                            let start = max(0, i - 1)
                            let end = min(lines.count, i + 2)
                            contextLines.append(contentsOf: lines[start..<end])
                            break
                        }
                    }
                    let context = contextLines.joined(separator: "\n")
                    _lastErrorSetTime = now
                    DispatchQueue.main.async { [weak self] in
                        self?.appState.activeTabError = context
                        // Auto-dismiss after 10 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                            if self?.appState.activeTabError == context {
                                self?.appState.activeTabError = nil
                            }
                        }
                    }
                    return
                }
            }
        }

        private func makeDataHandler() -> (Data) -> Void {
            { [weak self] data in
                guard let self = self, self.alive else { return }
                self.enqueueData(data)
            }
        }

        private func makeClosedHandler() -> () -> Void {
            { [weak self] in
                guard let self = self, self.alive else { return }
                DispatchQueue.main.async {
                    if self.isLocal {
                        if let tv = self.terminalView {
                            tv.feed(text: "\r\n\u{1b}[33m--- 本地终端已退出 ---\u{1b}[0m\r\n")
                        }
                        if let tabIdx = self.appState.tabs.firstIndex(where: { $0.id == self.tabId }) {
                            self.appState.tabs[tabIdx].sessionId = nil
                        }
                    } else {
                        if let tv = self.terminalView {
                            tv.feed(text: "\r\n\u{1b}[33m--- 连接已关闭 · 输入 ⌘⇧R 或右键「重新连接」恢复 ---\u{1b}[0m\r\n")
                        }
                        if let sid = self.sessionId {
                            self.appState.handleChannelClosed(channelId: sid)
                        }
                    }
                }
            }
        }

        func connect() {
            if isLocal {
                connectLocal()
            } else {
                connectSSH()
            }
        }

        private func connectLocal() {
            let shell = LocalShell()
            localShell = shell
            shell.onData = makeDataHandler()
            shell.onClosed = makeClosedHandler()

            let fakeSid = "local-\(Int(Date().timeIntervalSince1970 * 1000))"
            sessionId = fakeSid

            DispatchQueue.main.async {
                self.appState.updateTabSessionId(self.tabId, sessionId: fakeSid)
                if let tv = self.terminalView {
                    let term = tv.getTerminal()
                    shell.start(cols: UInt16(term.cols), rows: UInt16(term.rows))
                } else {
                    shell.start()
                }
            }
        }

        private func connectSSH() {
            let dataHandler = makeDataHandler()
            let closedHandler = makeClosedHandler()
            Task {
                do {
                    let sid = try await OrbitBridge.shared.connectSSHAsync(serverId: serverId)
                    guard alive else { return }
                    sessionId = sid
                    OrbitBridge.shared.handlersLock.lock()
                    OrbitBridge.shared.sshDataHandlers[sid] = dataHandler
                    OrbitBridge.shared.sshClosedHandlers[sid] = closedHandler
                    OrbitBridge.shared.terminalViewCache[sid] = self.terminalView
                    OrbitBridge.shared.handlersLock.unlock()
                    appState.updateTabSessionId(tabId, sessionId: sid)
                    await MainActor.run {
                        if let tv = terminalView {
                            let term = tv.getTerminal()
                            do { try OrbitBridge.shared.resizeSSH(sessionId: sid, cols: UInt32(term.cols), rows: UInt32(term.rows)) } catch { print("[Orbit] resizeSSH(connect) failed: \(error)") }
                        }
                    }
                } catch {
                    guard alive else { return }
                    await MainActor.run {
                        terminalView?.feed(text: "\u{1b}[31m连接失败: \(error)\u{1b}[0m\r\n")
                    }
                }
            }
        }

        func registerHandlers() {
            if isLocal { return }
            guard let sid = sessionId else { return }
            OrbitBridge.shared.handlersLock.lock()
            OrbitBridge.shared.sshDataHandlers[sid] = makeDataHandler()
            OrbitBridge.shared.sshClosedHandlers[sid] = makeClosedHandler()
            OrbitBridge.shared.handlersLock.unlock()
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard alive else { return }
            let bytes = Data(data)

            // AI ! prefix interception
            if _aiMode {
                if bytes.contains(0x0d) || bytes.contains(0x0a) {
                    // Enter pressed — submit the question
                    _aiMode = false
                    let question = _aiBuffer.trimmingCharacters(in: .whitespaces)
                    _aiBuffer = ""
                    if !question.isEmpty {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .askAI, object: nil, userInfo: ["question": question])
                        }
                    }
                } else {
                    _aiBuffer.append(String(data: bytes, encoding: .utf8) ?? "")
                }
                return
            }

            // Detect ! prefix at the start of a new input
            let str = String(data: bytes, encoding: .utf8) ?? ""
            if str.hasPrefix("! ") {
                _aiMode = true
                let remaining = String(str.dropFirst(2))
                // Check if Enter is embedded in the same chunk (e.g. paste)
                if let crIndex = remaining.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
                    let question = String(remaining[..<crIndex]).trimmingCharacters(in: .whitespaces)
                    _aiBuffer = ""
                    _aiMode = false
                    if !question.isEmpty {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .askAI, object: nil, userInfo: ["question": question])
                        }
                    }
                } else {
                    _aiBuffer = remaining
                }
                return
            }

            if isLocal {
                localShell?.write(bytes)
            } else if let sid = sessionId {
                do {
                    try OrbitBridge.shared.writeSSH(sessionId: sid, data: bytes)
                } catch {
                    print("[Orbit] writeSSH failed for session \(sid): \(error)")
                }
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard alive, newCols > 0, newRows > 0 else { return }
            if isLocal {
                localShell?.resize(cols: UInt16(newCols), rows: UInt16(newRows))
            } else if let sid = sessionId {
                do {
                    try OrbitBridge.shared.resizeSSH(sessionId: sid, cols: UInt32(newCols), rows: UInt32(newRows))
                } catch {
                    print("[Orbit] resizeSSH failed for session \(sid): \(error)")
                }
            }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }

        func bell(source: SwiftTerm.TerminalView) { NSSound.beep() }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            if let str = String(data: content, encoding: .utf8) {
                NSPasteboard.general.setString(str, forType: .string)
            }
        }

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
            // Auto-copy selected text to clipboard when selectToCopy is enabled
            guard UserDefaults.standard.bool(forKey: "selectToCopy") else { return }
            if let tv = terminalView, tv.selectionActive {
                tv.copy(tv)
            }
        }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    }
}
