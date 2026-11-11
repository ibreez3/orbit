import SwiftUI
import SwiftTerm
import AppKit

final class TerminalOutputPump {
    private static let defaultMaxBufferedBytes = 2 * 1024 * 1024
    private static let defaultChunkBytes = 64 * 1024
    private static let defaultMaxChunksPerFrame = 4

    private let maxBufferedBytes: Int
    private let chunkBytes: Int
    private let frameInterval: TimeInterval
    private let maxChunksPerFrame: Int
    private let condition = NSCondition()
    private let handleChunk: (Data, Int) -> Void

    private var pendingChunks: [Data] = []
    private var pendingHeadIndex = 0
    private var pendingOffset = 0
    private var pendingBytes = 0
    private var scheduled = false
    private var invalidated = false

    init(
        maxBufferedBytes: Int = TerminalOutputPump.defaultMaxBufferedBytes,
        chunkBytes: Int = TerminalOutputPump.defaultChunkBytes,
        frameInterval: TimeInterval = 1.0 / 120.0,
        maxChunksPerFrame: Int = TerminalOutputPump.defaultMaxChunksPerFrame,
        handleChunk: @escaping (Data, Int) -> Void
    ) {
        self.maxBufferedBytes = maxBufferedBytes
        self.chunkBytes = chunkBytes
        self.frameInterval = frameInterval
        self.maxChunksPerFrame = maxChunksPerFrame
        self.handleChunk = handleChunk
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }

        condition.lock()
        if !Thread.isMainThread {
            let deadline = Date().addingTimeInterval(0.1)
            while !invalidated && pendingBytes >= maxBufferedBytes && Date() < deadline {
                condition.wait(until: min(Date().addingTimeInterval(0.02), deadline))
            }
        }

        guard !invalidated else {
            condition.unlock()
            return
        }

        pendingChunks.append(data)
        pendingBytes += data.count
        if !scheduled {
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.drainOnMain()
            }
        }
        condition.unlock()
    }

    func invalidate() {
        condition.lock()
        invalidated = true
        scheduled = false
        pendingChunks.removeAll(keepingCapacity: false)
        pendingHeadIndex = 0
        pendingOffset = 0
        pendingBytes = 0
        condition.broadcast()
        condition.unlock()
    }

    private func drainOnMain() {
        var chunks: [(Data, Int)] = []

        condition.lock()
        guard !invalidated else {
            scheduled = false
            condition.broadcast()
            condition.unlock()
            return
        }

        var processed = 0
        while processed < maxChunksPerFrame && pendingBytes > 0 {
            let take = min(pendingBytes, chunkBytes)
            let chunk = popPendingBytes(take)
            chunks.append((chunk, pendingBytes))
            processed += 1
        }
        condition.broadcast()
        condition.unlock()

        for (chunk, queuedBytes) in chunks where !chunk.isEmpty {
            handleChunk(chunk, queuedBytes)
        }

        condition.lock()
        if invalidated || pendingBytes == 0 {
            scheduled = false
            condition.broadcast()
            condition.unlock()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) { [weak self] in
            self?.drainOnMain()
        }
        condition.unlock()
    }

    private func popPendingBytes(_ count: Int) -> Data {
        var remaining = count
        var chunk = Data()
        chunk.reserveCapacity(count)

        while remaining > 0 && pendingHeadIndex < pendingChunks.count {
            let current = pendingChunks[pendingHeadIndex]
            let available = current.count - pendingOffset
            if available <= 0 {
                pendingHeadIndex += 1
                pendingOffset = 0
                continue
            }

            let take = min(available, remaining)
            let start = current.index(current.startIndex, offsetBy: pendingOffset)
            let end = current.index(start, offsetBy: take)
            chunk.append(contentsOf: current[start..<end])
            pendingOffset += take
            pendingBytes -= take
            remaining -= take

            if pendingOffset >= current.count {
                pendingHeadIndex += 1
                pendingOffset = 0
            }
        }

        compactPendingChunksIfNeeded()
        return chunk
    }

    private func compactPendingChunksIfNeeded() {
        if pendingBytes == 0 {
            pendingChunks.removeAll(keepingCapacity: true)
            pendingHeadIndex = 0
            pendingOffset = 0
            return
        }

        guard pendingHeadIndex > 32 && pendingHeadIndex * 2 >= pendingChunks.count else {
            return
        }
        pendingChunks.removeFirst(pendingHeadIndex)
        pendingHeadIndex = 0
    }

    static func feed(_ data: Data, to terminalView: SwiftTerm.TerminalView) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { buf in
            if let base = buf.bindMemory(to: UInt8.self).baseAddress {
                let slice = ArraySlice(UnsafeBufferPointer(start: base, count: data.count))
                terminalView.feed(byteArray: slice)
            }
        }
    }
}

// MARK: - Keyword Injection

enum KeywordInjector {
    private static let regexCache = NSCache<NSString, NSRegularExpression>()
    private static let regexMetaCharacters = CharacterSet(charactersIn: #"\\.^$*+?()[]{}|"#)

    static func highlight(_ data: Data, keywords: [KeywordHighlight]) -> Data {
        let enabled = keywords.filter { $0.enabled && !$0.pattern.isEmpty }
        guard !enabled.isEmpty else { return data }

        var allRulesHaveNeedles = true
        var hasNeedleMatch = false
        for rule in enabled {
            guard let needle = prefilterNeedle(for: rule.pattern) else {
                allRulesHaveNeedles = false
                continue
            }
            if containsASCII(data, needle: needle) {
                hasNeedleMatch = true
                break
            }
        }
        if allRulesHaveNeedles && !hasNeedleMatch {
            return data
        }

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

    private static func isLiteralPattern(_ pattern: String) -> Bool {
        pattern.rangeOfCharacter(from: regexMetaCharacters) == nil
    }

    private static func prefilterNeedle(for pattern: String) -> [UInt8]? {
        if isLiteralPattern(pattern) {
            return asciiNeedle(pattern)
        }

        guard let firstMeta = pattern.firstIndex(where: { character in
            String(character).rangeOfCharacter(from: regexMetaCharacters) != nil
        }), pattern[firstMeta] == "(" else {
            return nil
        }

        let prefix = String(pattern[..<firstMeta])
        return asciiNeedle(prefix)
    }

    private static func asciiNeedle(_ text: String) -> [UInt8]? {
        let bytes = text.utf8.map { lowercaseASCII($0) }
        return bytes.isEmpty ? nil : bytes
    }

    private static func containsASCII(_ data: Data, needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            let haystack = UnsafeBufferPointer(start: base, count: data.count)
            let lastStart = haystack.count - needle.count

            for start in 0...lastStart {
                var matched = true
                for offset in 0..<needle.count where lowercaseASCII(haystack[start + offset]) != needle[offset] {
                    matched = false
                    break
                }
                if matched {
                    return true
                }
            }
            return false
        }
    }

    private static func lowercaseASCII(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static func hexToAnsi(_ hex: String) -> String {
        let hexStr = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
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
    let connectionTarget: ServerConnectionTarget
    let tabId: String
    var sessionGeneration: Int = 0
    @EnvironmentObject var themeState: ThemeState
    let appState: AppState

    private static func applySettings(_ tv: OrbitTerminalView, theme: AppTheme) {
        tv.configureRenderSettings(theme: theme)
    }

    private var isLocalTarget: Bool {
        if case .local = connectionTarget {
            return true
        }
        return false
    }

    func makeNSView(context: Context) -> OrbitTerminalView {
        // Reuse cached terminal view if available (preserves buffer on pane tree changes)
        if let cid = channelId, let cached = OrbitBridge.shared.terminalView(for: cid) as? OrbitTerminalView {
            context.coordinator.sessionId = cid
            context.coordinator.terminalView = cached
            cached.terminalDelegate = context.coordinator
            context.coordinator.refreshInteractionState()
            if isLocalTarget {
                context.coordinator.adoptLocalShell()
            } else {
                context.coordinator.registerHandlers()
                let term = cached.terminalDimensions
                context.coordinator.resizeTransport(cols: term.cols, rows: term.rows)
            }
            Self.applySettings(cached, theme: themeState.theme)
            return cached
        }

        let tv = OrbitTerminalView()
        tv.tabId = tabId
        tv.appState = appState
        Self.applySettings(tv, theme: themeState.theme)
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.refreshInteractionState()

        if isLocalTarget {
            if let cid = channelId {
                context.coordinator.sessionId = cid
                OrbitBridge.shared.cacheTerminalView(tv, sessionId: cid)
            }
            context.coordinator.connect()
        } else if let cid = channelId {
            context.coordinator.sessionId = cid
            OrbitBridge.shared.cacheTerminalView(tv, sessionId: cid)
            context.coordinator.registerHandlers()
            let term = tv.terminalDimensions
            context.coordinator.resizeTransport(cols: term.cols, rows: term.rows)
        } else {
            context.coordinator.connect()
        }

        return tv
    }

    func updateNSView(_ nsView: OrbitTerminalView, context: Context) {
        if context.coordinator.sessionGeneration != sessionGeneration {
            context.coordinator.sessionGeneration = sessionGeneration
            context.coordinator.prepareForNewSession()
            if context.coordinator.isLocal {
                context.coordinator.restartLocal()
            } else {
                context.coordinator.sessionId = nil
            }
        }
        if let cid = channelId, context.coordinator.sessionId != cid {
            if context.coordinator.sessionId != nil {
                context.coordinator.prepareForNewSession()
            }
            context.coordinator.sessionId = cid
            if context.coordinator.isLocal {
                context.coordinator.adoptLocalShell()
            } else {
                context.coordinator.registerHandlers()
            }
        }
        nsView.tabId = tabId
        nsView.appState = appState
        Self.applySettings(nsView, theme: themeState.theme)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            channelId: channelId,
            connectionTarget: connectionTarget,
            tabId: tabId,
            sessionGeneration: sessionGeneration,
            appState: appState
        )
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        let channelId: String?
        let connectionTarget: ServerConnectionTarget
        let tabId: String
        let appState: AppState
        weak var terminalView: OrbitTerminalView?
        var sessionId: String?
        var sessionGeneration: Int
        private var alive = true
        private var localShell: LocalShell?
        private let outputPumpLock = NSLock()
        private var outputPump: TerminalOutputPump?

        // AI ! prefix question buffer
        private var _aiBuffer = ""
        private var _aiMode = false
        private var inputState: TerminalInputStateSnapshot?
        private var interactionMode: TerminalOutputPolicy.InteractionMode = .normalShell

        // Error detection throttling
        private var _lastErrorScanTime: Date = .distantPast
        private var _lastErrorSetTime: Date = .distantPast

        var isLocal: Bool {
            if case .local = connectionTarget {
                return true
            }
            return false
        }

        init(
            channelId: String?,
            connectionTarget: ServerConnectionTarget,
            tabId: String,
            sessionGeneration: Int,
            appState: AppState
        ) {
            self.channelId = channelId
            self.connectionTarget = connectionTarget
            self.tabId = tabId
            self.sessionGeneration = sessionGeneration
            self.appState = appState
        }

        deinit {
            alive = false
            outputPump?.invalidate()
            localShell = nil
        }

        private func enqueueData(_ data: Data) {
            outputPumpLock.lock()
            if outputPump == nil {
                outputPump = makeOutputPump()
            }
            let pump = outputPump
            outputPumpLock.unlock()
            pump?.enqueue(data)
        }

        private func makeOutputPump() -> TerminalOutputPump {
            TerminalOutputPump { [weak self] data, queuedBytes in
                guard let self = self, self.alive, let tv = self.terminalView else { return }
                self.handleOutput(data, queuedBytes: queuedBytes, terminalView: tv)
            }
        }

        func handleOutput(_ data: Data, queuedBytes: Int, terminalView tv: OrbitTerminalView) {
            let focusedSessionId = appState.tabState.tab(id: tabId).flatMap { $0.focusedChannelId ?? $0.sessionId }
            let policy = TerminalOutputPolicy(
                snapshot: inputState ?? tv.terminalInputStateSnapshot(), backlog: queuedBytes,
                isActiveTab: appState.activeTabId == tabId,
                isFocusedPane: sessionId != nil && focusedSessionId == sessionId,
                keywordsEnabled: appState.keywordHighlights.contains { $0.enabled && !$0.pattern.isEmpty },
                forceTUI: TerminalOutputPolicy.chunkEntersTUI(data)
            )
#if DEBUG
            if policy.shouldInjectKeywords { tv.keywordInjectionCount += 1 }
            if policy.shouldScanErrors { tv.errorScanCount += 1 }
#endif
            let output = policy.shouldInjectKeywords
                ? KeywordInjector.highlight(data, keywords: appState.keywordHighlights) : data
            if policy.shouldScanErrors { scanForErrors(in: data) }
            TerminalOutputPump.feed(output, to: tv)
            refreshInteractionState()
        }

        func refreshInteractionState() {
            guard let terminalView else { return }
            inputState = terminalView.terminalInputStateSnapshot()
            let policy = TerminalOutputPolicy(
                snapshot: inputState, backlog: 0, isActiveTab: false,
                isFocusedPane: false, keywordsEnabled: false
            )
            interactionMode = policy.interactionMode
            if policy.isTUI {
                _aiMode = false
                _aiBuffer = ""
            }
            terminalView.setTUIInteractionActive(policy.isTUI)
        }

        /// A new shell must not inherit alternate-screen/mouse modes from a
        /// TUI that died without restoring the terminal.
        func prepareForNewSession() {
            terminalView?.resetForNewSession()
            inputState = nil
            interactionMode = .normalShell
            _aiMode = false
            _aiBuffer = ""
            refreshInteractionState()
        }

        private static let errorPatterns: [(String, String)] = [
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

        private func scanForErrors(in data: Data) {
            let now = Date()
            guard now.timeIntervalSince(_lastErrorScanTime) >= 2.0 else { return }
            _lastErrorScanTime = now

            guard now.timeIntervalSince(_lastErrorSetTime) >= 3.0 else { return }

            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }

            for (pattern, _) in Self.errorPatterns {
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
                    if let sessionId,
                       let generation = appState.setActiveTabError(context, tabId: tabId, sessionId: sessionId) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                            self?.appState.clearActiveTabError(matchingGeneration: generation)
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
                        if let tabIdx = self.appState.tabs.firstIndex(where: { $0.id == self.tabId }),
                           self.appState.tabs[tabIdx].paneTree == nil {
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

        /// Reattaches a rebuilt view to the shell already running for this pane.
        /// A shell that has already exited stays exited until explicitly restarted.
        func adoptLocalShell() {
            guard isLocal else { return }
            guard let shell = terminalView?.localShell else { return }
            localShell = shell
            guard shell.isRunning else { return }
            shell.onData = makeDataHandler()
            shell.onClosed = makeClosedHandler()
            if let term = terminalView?.terminalDimensions {
                resizeTransport(cols: term.cols, rows: term.rows)
            }
        }

        private func connectLocal(reuseId: String? = nil) {
            prepareForNewSession()
            if let existing = terminalView?.localShell, existing.isRunning {
                adoptLocalShell()
                return
            }

            let effectiveId = channelId
                ?? reuseId
                ?? sessionId
                ?? "local-\(Int(Date().timeIntervalSince1970 * 1000))"
            let shell = LocalShell()
            localShell = shell
            terminalView?.localShell = shell
            shell.onData = makeDataHandler()
            shell.onClosed = makeClosedHandler()
            sessionId = effectiveId

            DispatchQueue.main.async {
                if self.channelId == nil {
                    self.appState.updateTabSessionId(self.tabId, sessionId: effectiveId)
                }
                if let tv = self.terminalView {
                    OrbitBridge.shared.cacheTerminalView(tv, sessionId: effectiveId)
                    let term = tv.terminalDimensions
                    shell.start(cols: UInt16(term.cols), rows: UInt16(term.rows))
                } else {
                    shell.start()
                }
                self.scheduleInitialCommandForLocalShell()
            }
        }

        func restartLocal() {
            guard isLocal else { return }
            prepareForNewSession()
            let previousId = sessionId ?? channelId
            terminalView?.resizeDeduplicator.reset()
            localShell?.stop()
            if terminalView?.localShell === localShell {
                terminalView?.localShell = nil
            }
            localShell = nil
            sessionId = nil
            connectLocal(reuseId: previousId)
        }

        private func connectSSH() {
            prepareForNewSession()
            let dataHandler = makeDataHandler()
            let closedHandler = makeClosedHandler()
            Task {
                do {
                    let sid = try await appState.connectSSH(for: connectionTarget)
                    await MainActor.run {
                        sessionId = sid
                    }
                    let installed = await appState.installSSHSession(
                        tabId: tabId,
                        expectedTarget: connectionTarget,
                        sessionId: sid,
                        dataHandler: dataHandler,
                        closedHandler: closedHandler
                    )
                    guard installed else {
                        await MainActor.run { sessionId = nil }
                        return
                    }
                    await MainActor.run {
                        if let terminalView = self.terminalView {
                            OrbitBridge.shared.cacheTerminalView(terminalView, sessionId: sid)
                        }
                        if let tv = terminalView {
                            let term = tv.terminalDimensions
                            self.resizeTransport(cols: term.cols, rows: term.rows)
                        }
                        self.scheduleInitialCommandForSSH(sessionId: sid)
                    }
                } catch {
                    guard alive else { return }
                    await MainActor.run {
                        terminalView?.feed(text: "\u{1b}[31m连接失败: \(error)\u{1b}[0m\r\n")
                    }
                }
            }
        }

        private func scheduleInitialCommandForLocalShell() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.alive, let shell = self.localShell else { return }
                guard let command = self.appState.consumeInitialCommand(tabId: self.tabId),
                      !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                shell.write(Data((command + "\r").utf8))
            }
        }

        private func scheduleInitialCommandForSSH(sessionId: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.alive else { return }
                guard let command = self.appState.consumeInitialCommand(tabId: self.tabId),
                      !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do {
                    try OrbitBridge.shared.writeSSH(sessionId: sessionId, data: Data((command + "\r").utf8))
                } catch {
                    print("[Orbit] initial command failed for session \(sessionId): \(error)")
                }
            }
        }

        func registerHandlers() {
            if isLocal { return }
            guard let sid = sessionId else { return }
            OrbitBridge.shared.setSSHHandlers(sessionId: sid, dataHandler: makeDataHandler(), closedHandler: makeClosedHandler())
        }

        @MainActor func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard alive else { return }
            let bytes = Data(data)

            // AI ! prefix interception
            if interactionMode == .normalShell && _aiMode {
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
            if interactionMode == .normalShell && str.hasPrefix("! ") {
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

        @MainActor func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
#if DEBUG
            (source as? OrbitTerminalView)?.sizeChangedCount += 1
#endif
            resizeTransport(cols: newCols, rows: newRows)
        }

        func resizeTransport(cols: Int, rows: Int) {
            guard alive, let sid = sessionId, let tv = terminalView,
                  tv.resizeDeduplicator.needsResize(sessionId: sid, cols: cols, rows: rows) else { return }
            if isLocal {
                guard let localShell, localShell.isRunning else { return }
                guard localShell.resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows)) else {
                    return
                }
            } else {
                do {
                    try OrbitBridge.shared.resizeSSH(sessionId: sid, cols: UInt32(cols), rows: UInt32(rows))
                } catch {
                    print("[Orbit] resizeSSH failed for session \(sid): \(error)")
                    return
                }
            }
            tv.resizeDeduplicator.record(sessionId: sid, cols: cols, rows: rows)
        }

        @MainActor func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        @MainActor func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        @MainActor func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        @MainActor func requestOpenLink(source: SwiftTerm.TerminalView, request: TerminalLinkRequest) {
            request.openDefault()
        }

        @MainActor func bell(source: SwiftTerm.TerminalView) { NSSound.beep() }

        @MainActor func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            if let str = String(data: content, encoding: .utf8) {
                NSPasteboard.general.setString(str, forType: .string)
            }
        }

        @MainActor func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

        @MainActor func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    }
}
