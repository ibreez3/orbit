import Foundation

@_cdecl("orbitDataCallback")
private func orbitDataCallback(sessionId: UnsafePointer<CChar>?, data: UnsafePointer<UInt8>?, len: Int, userdata: UnsafeMutableRawPointer?) {
    guard let userdata = userdata, let sessionId = sessionId, let data = data else { return }
    let manager = Unmanaged<OrbitBridge>.fromOpaque(userdata).takeUnretainedValue()
    let sid = String(cString: sessionId)
    let bytes = Data(bytes: data, count: len)
    manager.handleSSHData(sessionId: sid, data: bytes)
}

@_cdecl("orbitClosedCallback")
private func orbitClosedCallback(sessionId: UnsafePointer<CChar>?, userdata: UnsafeMutableRawPointer?) {
    guard let userdata = userdata, let sessionId = sessionId else { return }
    let manager = Unmanaged<OrbitBridge>.fromOpaque(userdata).takeUnretainedValue()
    let sid = String(cString: sessionId)
    manager.handleSSHClosed(sessionId: sid)
}

@_cdecl("orbitProgressCallback")
private func orbitProgressCallback(serverId: UnsafePointer<CChar>?, transferred: UInt64, total: UInt64, userdata: UnsafeMutableRawPointer?) {
    guard let userdata = userdata, let serverId = serverId else { return }
    let manager = Unmanaged<OrbitBridge>.fromOpaque(userdata).takeUnretainedValue()
    let sid = String(cString: serverId)
    manager.handleProgress(serverId: sid, transferred: transferred, total: total)
}

class OrbitBridge {
    static let shared = OrbitBridge()

    private var app: OpaquePointer?
    private let initLock = NSLock()
    var sshDataHandlers: [String: (Data) -> Void] = [:]
    var sshClosedHandlers: [String: () -> Void] = [:]
    var progressHandlers: [String: (UInt64, UInt64) -> Void] = [:]

    private init() {}

    func ensureInitialized() throws {
        initLock.lock()
        defer { initLock.unlock() }
        if app != nil { return }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let orbitDir = appSupport.appendingPathComponent("orbit", isDirectory: true)
        try FileManager.default.createDirectory(at: orbitDir, withIntermediateDirectories: true)
        let dbPath = orbitDir.appendingPathComponent("orbit.db").path
        app = dbPath.withCString { path in
            orbit_app_new(path)
        }
        guard app != nil else {
            throw OrbitError.initializationFailed
        }
    }

    deinit {
        if let app = app {
            orbit_app_free(app)
        }
    }

    func handleSSHData(sessionId: String, data: Data) {
        sshDataHandlers[sessionId]?(data)
    }

    func handleSSHClosed(sessionId: String) {
        sshClosedHandlers[sessionId]?()
    }

    func handleProgress(serverId: String, transferred: UInt64, total: UInt64) {
        progressHandlers[serverId]?(transferred, total)
    }

    // MARK: - Server CRUD

    func listServers() throws -> [Server] {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = orbit_list_servers(app, &outJson)
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try JSONDecoder().decode([Server].self, from: String(cString: json).data(using: .utf8)!)
    }

    func addServer(input: ServerInput) throws -> Server {
        try ensureInitialized()
        let jsonData = try JSONEncoder().encode(input)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = jsonString.withCString { inputPtr in
            orbit_add_server(app, inputPtr, &outJson)
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try JSONDecoder().decode(Server.self, from: String(cString: json).data(using: .utf8)!)
    }

    func updateServer(id: String, input: ServerInput) throws -> Server {
        try ensureInitialized()
        let jsonData = try JSONEncoder().encode(input)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = id.withCString { idPtr in
            jsonString.withCString { inputPtr in
                orbit_update_server(app, idPtr, inputPtr, &outJson)
            }
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try JSONDecoder().decode(Server.self, from: String(cString: json).data(using: .utf8)!)
    }

    func deleteServer(id: String) throws {
        try ensureInitialized()
        let rc = id.withCString { idPtr in
            orbit_delete_server(app, idPtr)
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
    }

    func testConnection(input: ServerInput) throws -> Bool {
        try ensureInitialized()
        let jsonData = try JSONEncoder().encode(input)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        let rc = jsonString.withCString { inputPtr in
            orbit_test_connection(app, inputPtr)
        }
        return rc == 1
    }

    // MARK: - Credential Group CRUD

    func listCredentialGroups() throws -> [CredentialGroup] {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = orbit_list_credential_groups(app, &outJson)
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try JSONDecoder().decode([CredentialGroup].self, from: String(cString: json).data(using: .utf8)!)
    }

    func addCredentialGroup(input: CredentialGroupInput) throws -> CredentialGroup {
        try ensureInitialized()
        let jsonData = try JSONEncoder().encode(input)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = jsonString.withCString { inputPtr in
            orbit_add_credential_group(app, inputPtr, &outJson)
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try JSONDecoder().decode(CredentialGroup.self, from: String(cString: json).data(using: .utf8)!)
    }

    func updateCredentialGroup(id: String, input: CredentialGroupInput) throws -> CredentialGroup {
        try ensureInitialized()
        let jsonData = try JSONEncoder().encode(input)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = id.withCString { idPtr in
            jsonString.withCString { inputPtr in
                orbit_update_credential_group(app, idPtr, inputPtr, &outJson)
            }
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try JSONDecoder().decode(CredentialGroup.self, from: String(cString: json).data(using: .utf8)!)
    }

    func deleteCredentialGroup(id: String) throws {
        try ensureInitialized()
        let rc = id.withCString { idPtr in
            orbit_delete_credential_group(app, idPtr)
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
    }

    // MARK: - SSH

    func connectSSH(serverId: String) throws -> String {
        try ensureInitialized()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var outSessionId: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            orbit_connect_ssh(app, sidPtr, orbitDataCallback, orbitClosedCallback, selfPtr, &outSessionId)
        }
        guard rc == 0, let sessionId = outSessionId else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(sessionId) }
        return String(cString: sessionId)
    }

    func writeSSH(sessionId: String, data: Data) throws {
        try ensureInitialized()
        let rc = data.withUnsafeBytes { buf in
            sessionId.withCString { sidPtr in
                orbit_write_ssh(app, sidPtr, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), buf.count)
            }
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
    }

    func resizeSSH(sessionId: String, cols: UInt32, rows: UInt32) throws {
        try ensureInitialized()
        let rc = sessionId.withCString { sidPtr in
            orbit_resize_ssh(app, sidPtr, cols, rows)
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
    }

    func disconnectSSH(sessionId: String) throws {
        try ensureInitialized()
        let rc = sessionId.withCString { sidPtr in
            orbit_disconnect_ssh(app, sidPtr)
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
    }

    func getSSHTraffic(sessionId: String) throws -> (read: UInt64, written: UInt64) {
        try ensureInitialized()
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        let rc = sessionId.withCString { sidPtr in
            orbit_get_ssh_traffic(app, sidPtr, &bytesRead, &bytesWritten)
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
        return (bytesRead, bytesWritten)
    }

    // MARK: - SFTP

    func sftpList(serverId: String, path: String) throws -> [FileEntry] {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            path.withCString { pathPtr in
                orbit_sftp_list(app, sidPtr, pathPtr, &outJson)
            }
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try JSONDecoder().decode([FileEntry].self, from: String(cString: json).data(using: .utf8)!)
    }

    func sftpListFast(serverId: String, path: String) throws -> [FileEntry] {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            path.withCString { pathPtr in
                orbit_sftp_list_fast(app, sidPtr, pathPtr, &outJson)
            }
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try JSONDecoder().decode([FileEntry].self, from: String(cString: json).data(using: .utf8)!)
    }

    func sftpStatDirEntries(serverId: String, path: String) throws -> [FileEntryStat] {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            path.withCString { pathPtr in
                orbit_sftp_stat_dir_entries(app, sidPtr, pathPtr, &outJson)
            }
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try JSONDecoder().decode([FileEntryStat].self, from: String(cString: json).data(using: .utf8)!)
    }

    func sftpDownload(serverId: String, remotePath: String, localPath: String) throws {
        try ensureInitialized()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let rc = serverId.withCString { sidPtr in
            remotePath.withCString { remotePtr in
                localPath.withCString { localPtr in
                    orbit_sftp_download(app, sidPtr, remotePtr, localPtr, orbitProgressCallback, selfPtr)
                }
            }
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
    }

    func sftpUpload(serverId: String, localPath: String, remotePath: String) throws {
        try ensureInitialized()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let rc = serverId.withCString { sidPtr in
            localPath.withCString { localPtr in
                remotePath.withCString { remotePtr in
                    orbit_sftp_upload(app, sidPtr, localPtr, remotePtr, orbitProgressCallback, selfPtr)
                }
            }
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
    }

    func sftpMkdir(serverId: String, path: String) throws {
        try ensureInitialized()
        let rc = serverId.withCString { sidPtr in
            path.withCString { pathPtr in
                orbit_sftp_mkdir(app, sidPtr, pathPtr)
            }
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
    }

    func sftpRemove(serverId: String, path: String, isDir: Bool) throws {
        try ensureInitialized()
        let rc = serverId.withCString { sidPtr in
            path.withCString { pathPtr in
                orbit_sftp_remove(app, sidPtr, pathPtr, isDir)
            }
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
    }

    // MARK: - Monitor

    func getServerStats(serverId: String) throws -> ServerStats {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            orbit_get_server_stats(app, sidPtr, &outJson)
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try JSONDecoder().decode(ServerStats.self, from: String(cString: json).data(using: .utf8)!)
    }

    func getServerHome(serverId: String) throws -> String {
        try ensureInitialized()
        var outHome: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            orbit_get_server_home(app, sidPtr, &outHome)
        }
        guard rc == 0, let home = outHome else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(home) }
        return String(cString: home)
    }
}

enum OrbitError: LocalizedError {
    case notInitialized
    case initializationFailed
    case apiError(Int32)

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "OrbitApp not initialized"
        case .initializationFailed: return "Failed to initialize OrbitApp"
        case .apiError(let rc): return "API error: code \(rc)"
        }
    }
}
