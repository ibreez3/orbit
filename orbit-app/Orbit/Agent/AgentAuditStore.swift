import AgentKit
import Foundation

final class AgentAuditStore {
    static let shared = AgentAuditStore(logURL: AgentPaths.auditLogURL)

    private let logURL: URL
    private let lock = NSLock()
    private var events: [AgentAuditEvent] = []
    private let encoder: JSONEncoder

    init(logURL: URL) {
        self.logURL = logURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func record(_ event: AgentAuditEvent) {
        lock.lock()
        events.append(event)
        if events.count > 500 {
            events.removeFirst(events.count - 500)
        }
        lock.unlock()
        appendToLog(event)
    }

    func recent(limit: Int = 100) -> [AgentAuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(events.suffix(max(0, limit)))
    }

    func flush() {
        // Each record is written synchronously; kept for callers that batch.
    }

    private func appendToLog(_ event: AgentAuditEvent) {
        guard let data = try? encoder.encode(event) else { return }
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([0x0A]))
    }
}
