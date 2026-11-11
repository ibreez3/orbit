import XCTest
import SwiftTerm
@testable import Orbit

@MainActor
final class TerminalOutputPolicyTests: XCTestCase {
    private func policy(_ snapshot: TerminalInputStateSnapshot?, backlog: Int = 0,
                        active: Bool = true, focused: Bool = true, keywords: Bool = true) -> TerminalOutputPolicy {
        TerminalOutputPolicy(snapshot: snapshot, backlog: backlog, isActiveTab: active,
                             isFocusedPane: focused, keywordsEnabled: keywords)
    }

    func testAlternateBufferAndEveryMouseModeDisableDecorations() throws {
        for mode in [1049, 9, 1000, 1002, 1003] {
            let view = OrbitTerminalView()
            view.feed(text: "\u{1b}[?\(mode)h")
            let result = policy(try XCTUnwrap(view.terminalInputStateSnapshot()))
            XCTAssertTrue(result.isTUI, "mode \(mode)")
            XCTAssertFalse(result.shouldInjectKeywords)
            XCTAssertFalse(result.shouldScanErrors)
            XCTAssertEqual(result.interactionMode, .tui)
        }
    }

    func testBracketedPasteAndNilSnapshotRemainNormalShell() {
        let view = OrbitTerminalView()
        view.feed(text: "\u{1b}[?2004h")
        for snapshot in [nil, view.terminalInputStateSnapshot()] {
            let result = policy(snapshot)
            XCTAssertFalse(result.isTUI)
            XCTAssertTrue(result.shouldInjectKeywords)
            XCTAssertTrue(result.shouldScanErrors)
        }
    }

    func testBacklogBoundaryKeywordToggleAndErrorOwnership() {
        XCTAssertTrue(policy(nil, backlog: 512 * 1024).shouldInjectKeywords)
        XCTAssertFalse(policy(nil, backlog: 512 * 1024 + 1).shouldInjectKeywords)
        XCTAssertFalse(policy(nil, keywords: false).shouldInjectKeywords)
        XCTAssertFalse(policy(nil, active: false).shouldScanErrors)
        XCTAssertFalse(policy(nil, focused: false).shouldScanErrors)
        XCTAssertTrue(policy(nil, active: false).shouldInjectKeywords)
    }

    func testChunkEnteringTUIForcesPolicyBeforeNextSnapshot() {
        XCTAssertTrue(TerminalOutputPolicy.chunkEntersTUI(Data("\u{1b}[?1049h".utf8)))
        XCTAssertTrue(TerminalOutputPolicy.chunkEntersTUI(Data("prefix\u{1b}[?1000h".utf8)))
        XCTAssertFalse(TerminalOutputPolicy.chunkEntersTUI(Data("plain ERROR".utf8)))

        let result = TerminalOutputPolicy(
            snapshot: nil, backlog: 0, isActiveTab: true, isFocusedPane: true,
            keywordsEnabled: true, forceTUI: true
        )
        XCTAssertTrue(result.isTUI)
        XCTAssertFalse(result.shouldInjectKeywords)
        XCTAssertFalse(result.shouldScanErrors)
    }

    func testOutputPipelineLeavesTUIBytesUndecoratedAndRestoresShellHighlighting() throws {
        let state = AppState()
        state.tabs = [TabItem(id: "tab", type: .terminal, serverId: nil, connectionTarget: .local,
                             serverName: "Local", title: "Local", sessionId: "session")]
        state.activeTabId = "tab"
        state.keywordHighlights = [KeywordHighlight(id: "error", pattern: "ERROR", colorHex: "#ff0000", enabled: true)]
        let view = OrbitTerminalView()
        let coordinator = TerminalView.Coordinator(channelId: "session", connectionTarget: .local,
                                                    tabId: "tab", sessionGeneration: 0, appState: state)
        coordinator.terminalView = view
        coordinator.sessionId = "session"
        func feed(_ text: String) { coordinator.handleOutput(Data(text.utf8), queuedBytes: 0, terminalView: view) }
        feed("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[2J\u{1b}[H")
        feed("ERROR: 中文")
        let tui = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport))
        XCTAssertEqual(tui.rows[0].cells[0].attribute.fg, .defaultColor)
        XCTAssertNil(state.tabState.activeTabError)

        feed("\u{1b}[?1000l\u{1b}[?1049l\u{1b}[2J\u{1b}[H")
        feed("ERROR: shell")
        let shell = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport))
        XCTAssertNotEqual(shell.rows[0].cells[0].attribute.fg, .defaultColor)
    }

    func testEnteringTUIDiscardsPendingAIQuestionAndDoesNotInterceptNewQuestion() async {
        let state = AppState()
        let view = OrbitTerminalView()
        let coordinator = TerminalView.Coordinator(channelId: nil, connectionTarget: .local,
                                                    tabId: "tab", sessionGeneration: 0, appState: state)
        coordinator.terminalView = view
        let unexpected = expectation(forNotification: .askAI, object: nil)
        unexpected.isInverted = true
        coordinator.send(source: view, data: Array("! pending".utf8)[...])
        coordinator.handleOutput(Data("\u{1b}[?1049h".utf8), queuedBytes: 0, terminalView: view)
        coordinator.send(source: view, data: Array("! agent command\r".utf8)[...])
        coordinator.handleOutput(Data("\u{1b}[?1049l".utf8), queuedBytes: 0, terminalView: view)
        coordinator.send(source: view, data: [0x0d][...])
        await fulfillment(of: [unexpected], timeout: 0.1)
    }
}
