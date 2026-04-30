import SwiftUI
import SwiftTerm
import AppKit
import CoreText

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
            // Enable ligatures via font descriptor
            let descriptor = font.fontDescriptor.addingAttributes([
                .featureSettings: [
                    [kCTFontFeatureTypeIdentifierKey: 1,  // kLigaturesType
                     kCTFontFeatureSelectorIdentifierKey: 2]  // kCommonLigaturesOnSelector
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
                try? OrbitBridge.shared.resizeSSH(sessionId: cid, cols: UInt32(term.cols), rows: UInt32(term.rows))
            }
            return cached
        }

        let tv = OrbitTerminalView()
        tv.tabId = tabId
        tv.appState = appState
        // Enable Metal GPU rendering on Mac
        if UserDefaults.standard.bool(forKey: "useMetalRenderer") {
            try? tv.setUseMetal(true)
        }
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
                try? OrbitBridge.shared.resizeSSH(sessionId: cid, cols: UInt32(term.cols), rows: UInt32(term.rows))
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

        private func makeDataHandler() -> (Data) -> Void {
            { [weak self] data in
                guard let self = self, self.alive, let tv = self.terminalView else { return }
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
                    let sid = try OrbitBridge.shared.connectSSH(serverId: serverId)
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
                            try? OrbitBridge.shared.resizeSSH(sessionId: sid, cols: UInt32(term.cols), rows: UInt32(term.rows))
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
            if isLocal {
                localShell?.write(bytes)
            } else if let sid = sessionId {
                try? OrbitBridge.shared.writeSSH(sessionId: sid, data: bytes)
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard alive, newCols > 0, newRows > 0 else { return }
            if isLocal {
                localShell?.resize(cols: UInt16(newCols), rows: UInt16(newRows))
            } else if let sid = sessionId {
                try? OrbitBridge.shared.resizeSSH(sessionId: sid, cols: UInt32(newCols), rows: UInt32(newRows))
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
