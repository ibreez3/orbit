import SwiftUI
import SwiftTerm
import AppKit

struct TerminalView: NSViewRepresentable {
    let channelId: String?
    let serverId: String
    let tabId: String
    @EnvironmentObject var appState: AppState

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        // Reuse cached terminal view if available (preserves buffer on pane tree changes)
        if let cid = channelId, let cached = OrbitBridge.shared.terminalViewCache[cid] as? SwiftTerm.TerminalView {
            context.coordinator.sessionId = cid
            context.coordinator.terminalView = cached
            cached.terminalDelegate = context.coordinator
            context.coordinator.registerHandlers()
            if let term = cached.getTerminal() as? Terminal {
                try? OrbitBridge.shared.resizeSSH(sessionId: cid, cols: UInt32(term.cols), rows: UInt32(term.rows))
            }
            return cached
        }

        let tv = SwiftTerm.TerminalView()

        let catppuccin: [SwiftTerm.Color] = [
            SwiftTerm.Color(red: 0x4547, green: 0x475a, blue: 0x4547),
            SwiftTerm.Color(red: 0xf38b, green: 0x8ba8, blue: 0xf38b),
            SwiftTerm.Color(red: 0xa6e3, green: 0xa1a6, blue: 0xa6e3),
            SwiftTerm.Color(red: 0xf9e2, green: 0xaff9, blue: 0xf9e2),
            SwiftTerm.Color(red: 0x89b4, green: 0xfa89, blue: 0x89b4),
            SwiftTerm.Color(red: 0xf5c2, green: 0xe7f5, blue: 0xf5c2),
            SwiftTerm.Color(red: 0x94e2, green: 0xd594, blue: 0x94e2),
            SwiftTerm.Color(red: 0xbac2, green: 0xdeba, blue: 0xbac2),
            SwiftTerm.Color(red: 0x585b, green: 0x7058, blue: 0x585b),
            SwiftTerm.Color(red: 0xf38b, green: 0xa8f3, blue: 0xf38b),
            SwiftTerm.Color(red: 0xa6e3, green: 0xa1a6, blue: 0xa6e3),
            SwiftTerm.Color(red: 0xf9e2, green: 0xaff9, blue: 0xf9e2),
            SwiftTerm.Color(red: 0x89b4, green: 0xfa89, blue: 0x89b4),
            SwiftTerm.Color(red: 0xf5c2, green: 0xe7f5, blue: 0xf5c2),
            SwiftTerm.Color(red: 0x94e2, green: 0xd594, blue: 0x94e2),
            SwiftTerm.Color(red: 0xa6ad, green: 0xc8a6, blue: 0xa6ad),
        ]
        tv.installColors(catppuccin)
        tv.nativeBackgroundColor = NSColor(red: 0.118, green: 0.118, blue: 0.180, alpha: 1)
        tv.nativeForegroundColor = NSColor(red: 0.804, green: 0.827, blue: 0.957, alpha: 1)
        tv.font = NSFont(name: "Menlo", size: 14)!
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv

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

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        if context.coordinator.sessionId == nil, let cid = channelId {
            context.coordinator.sessionId = cid
            context.coordinator.registerHandlers()
        }
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

        init(channelId: String?, serverId: String, tabId: String, appState: AppState) {
            self.channelId = channelId
            self.serverId = serverId
            self.tabId = tabId
            self.appState = appState
        }

        deinit {
            alive = false
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
                    if let tv = self.terminalView {
                        tv.feed(text: "\r\n\u{1b}[31m--- 连接已关闭 ---\u{1b}[0m\r\n")
                    }
                    if let sid = self.sessionId {
                        self.appState.handleChannelClosed(channelId: sid)
                    }
                }
            }
        }

        func connect() {
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
            guard let sid = sessionId else { return }
            OrbitBridge.shared.handlersLock.lock()
            OrbitBridge.shared.sshDataHandlers[sid] = makeDataHandler()
            OrbitBridge.shared.sshClosedHandlers[sid] = makeClosedHandler()
            OrbitBridge.shared.handlersLock.unlock()
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard alive, let sid = sessionId else { return }
            let bytes = Data(data)
            try? OrbitBridge.shared.writeSSH(sessionId: sid, data: bytes)
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard alive, let sid = sessionId, newCols > 0, newRows > 0 else { return }
            try? OrbitBridge.shared.resizeSSH(sessionId: sid, cols: UInt32(newCols), rows: UInt32(newRows))
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
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
