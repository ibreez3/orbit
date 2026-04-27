import SwiftUI
import SwiftTerm
import AppKit

struct TerminalView: NSViewRepresentable {
    let tab: TabItem
    @Environment(AppState.self) var appState

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
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

        if let sessionId = tab.sessionId {
            context.coordinator.sessionId = sessionId
            context.coordinator.registerHandlers()
        } else {
            context.coordinator.connect()
        }

        return tv
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        if context.coordinator.sessionId == nil, let sid = tab.sessionId {
            context.coordinator.sessionId = sid
            context.coordinator.registerHandlers()
            if let tv = context.coordinator.terminalView {
                let term = tv.getTerminal()
                try? OrbitBridge.shared.resizeSSH(sessionId: sid, cols: UInt32(term.cols), rows: UInt32(term.rows))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, appState: appState)
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        let tab: TabItem
        let appState: AppState
        weak var terminalView: SwiftTerm.TerminalView?
        var sessionId: String?
        private var alive = true

        init(tab: TabItem, appState: AppState) {
            self.tab = tab
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
                guard let self = self, self.alive, let tv = self.terminalView else { return }
                DispatchQueue.main.async {
                    tv.feed(text: "\r\n\u{1b}[31m--- 连接已关闭 ---\u{1b}[0m\r\n")
                }
            }
        }

        func connect() {
            let dataHandler = makeDataHandler()
            let closedHandler = makeClosedHandler()
            Task {
                do {
                    let sid = try OrbitBridge.shared.connectSSH(serverId: tab.serverId)
                    guard alive else { return }
                    sessionId = sid
                    OrbitBridge.shared.sshDataHandlers[sid] = dataHandler
                    OrbitBridge.shared.sshClosedHandlers[sid] = closedHandler
                    appState.updateTabSessionId(tab.id, sessionId: sid)
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
            OrbitBridge.shared.sshDataHandlers[sid] = makeDataHandler()
            OrbitBridge.shared.sshClosedHandlers[sid] = makeClosedHandler()
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard let sid = sessionId else { return }
            let bytes = Data(data)
            Task {
                try? OrbitBridge.shared.writeSSH(sessionId: sid, data: bytes)
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard let sid = sessionId else { return }
            Task {
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
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
