import Foundation

public enum AgentPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["ORBIT_AGENT_SUPPORT_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Orbit", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    public static var socketPath: String {
        supportDirectory.appendingPathComponent("agent.sock").path
    }

    public static var cliSessionsDirectory: URL {
        supportDirectory.appendingPathComponent("cli-sessions", isDirectory: true)
    }

    public static var auditLogURL: URL {
        supportDirectory.appendingPathComponent("audit.log")
    }

    /// Creates the agent support directory with owner-only permissions.
    public static func ensureSupportDirectory() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: supportDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: supportDirectory.path
            )
            return
        }
        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
