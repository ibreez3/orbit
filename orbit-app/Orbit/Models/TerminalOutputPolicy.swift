import Foundation
import SwiftTerm

struct TerminalOutputPolicy: Equatable {
    enum InteractionMode: Equatable {
        case normalShell
        case tui
    }

    private static let tuiEnableSequences: [Data] = [
        "\u{1b}[?1049h", "\u{1b}[?1047h", "\u{1b}[?47h",
        "\u{1b}[?1000h", "\u{1b}[?1002h", "\u{1b}[?1003h",
        "\u{1b}[?1005h", "\u{1b}[?1006h", "\u{1b}[?1015h", "\u{1b}[?1016h"
    ].map { Data($0.utf8) }

    /// The post-feed snapshot is authoritative, but a chunk that itself
    /// enables the alternate screen or mouse reporting should not be
    /// keyword-rewritten or error-scanned under the previous normal-shell
    /// policy.
    static func chunkEntersTUI(_ data: Data) -> Bool {
        tuiEnableSequences.contains { data.range(of: $0) != nil }
    }

    let isTUI: Bool
    let shouldInjectKeywords: Bool
    let shouldScanErrors: Bool
    let interactionMode: InteractionMode

    init(snapshot: TerminalInputStateSnapshot?, backlog: Int, isActiveTab: Bool,
         isFocusedPane: Bool, keywordsEnabled: Bool, forceTUI: Bool = false) {
        isTUI = forceTUI || (snapshot.map { $0.isAlternateBuffer || $0.mouseMode != .off } ?? false)
        shouldInjectKeywords = !isTUI && backlog <= 512 * 1024 && keywordsEnabled
        shouldScanErrors = !isTUI && isActiveTab && isFocusedPane
        interactionMode = isTUI ? .tui : .normalShell
    }
}
