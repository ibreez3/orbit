import Foundation

struct TerminalResizeDeduplicator {
    private var sessionId: String?
    private var cols = 0
    private var rows = 0

    func needsResize(sessionId: String, cols: Int, rows: Int) -> Bool {
        cols > 0 && rows > 0 && (self.sessionId != sessionId || self.cols != cols || self.rows != rows)
    }

    mutating func record(sessionId: String, cols: Int, rows: Int) {
        self.sessionId = sessionId
        self.cols = cols
        self.rows = rows
    }

    mutating func reset() {
        sessionId = nil
    }
}
