import Foundation
import AppKit

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
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    private final class WeakViewBox {
        weak var view: NSView?

        init(_ view: NSView) {
            self.view = view
        }
    }

    private var app: OpaquePointer?
    private let initLock = NSLock()
    let handlersLock = NSLock()
    var sshDataHandlers: [String: (Data) -> Void] = [:]
    var sshClosedHandlers: [String: () -> Void] = [:]
    var progressHandlers: [String: (UInt64, UInt64) -> Void] = [:]
    private var terminalViewCache: [String: WeakViewBox] = [:]

    private init() {}

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from json: UnsafePointer<CChar>) throws -> T {
        let data = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: json),
            count: strlen(json),
            deallocator: .none
        )
        return try decoder.decode(type, from: data)
    }

    private static func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8)!
    }

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
        handlersLock.lock()
        let handler = sshDataHandlers[sessionId]
        handlersLock.unlock()
        handler?(data)
    }

    func handleSSHClosed(sessionId: String) {
        handlersLock.lock()
        let handler = sshClosedHandlers[sessionId]
        handlersLock.unlock()
        handler?()
    }

    func handleProgress(serverId: String, transferred: UInt64, total: UInt64) {
        handlersLock.lock()
        let handler = progressHandlers[serverId]
        handlersLock.unlock()
        handler?(transferred, total)
    }

    func removeSSHHandlers(sessionId: String) {
        handlersLock.lock()
        sshDataHandlers.removeValue(forKey: sessionId)
        sshClosedHandlers.removeValue(forKey: sessionId)
        handlersLock.unlock()
    }

    func removeTerminalView(sessionId: String) {
        handlersLock.lock()
        terminalViewCache.removeValue(forKey: sessionId)
        handlersLock.unlock()
    }

    func terminalView(for sessionId: String) -> NSView? {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        guard let box = terminalViewCache[sessionId] else { return nil }
        if let view = box.view {
            return view
        }
        terminalViewCache.removeValue(forKey: sessionId)
        return nil
    }

    func cacheTerminalView(_ view: NSView, sessionId: String) {
        handlersLock.lock()
        terminalViewCache[sessionId] = WeakViewBox(view)
        handlersLock.unlock()
    }

    func setSSHHandlers(sessionId: String, dataHandler: @escaping (Data) -> Void, closedHandler: @escaping () -> Void) {
        handlersLock.lock()
        sshDataHandlers[sessionId] = dataHandler
        sshClosedHandlers[sessionId] = closedHandler
        handlersLock.unlock()
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
        return try Self.decodeJSON([Server].self, from: json)
    }

    func addServer(input: ServerInput) throws -> Server {
        try ensureInitialized()
        let jsonData = try Self.encoder.encode(input)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = jsonString.withCString { inputPtr in
            orbit_add_server(app, inputPtr, &outJson)
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try Self.decodeJSON(Server.self, from: json)
    }

    func updateServer(id: String, input: ServerInput) throws -> Server {
        try ensureInitialized()
        let jsonData = try Self.encoder.encode(input)
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
        return try Self.decodeJSON(Server.self, from: json)
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
        let jsonData = try Self.encoder.encode(input)
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
        return try Self.decodeJSON([CredentialGroup].self, from: json)
    }

    func addCredentialGroup(input: CredentialGroupInput) throws -> CredentialGroup {
        try ensureInitialized()
        let jsonData = try Self.encoder.encode(input)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = jsonString.withCString { inputPtr in
            orbit_add_credential_group(app, inputPtr, &outJson)
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try Self.decodeJSON(CredentialGroup.self, from: json)
    }

    func updateCredentialGroup(id: String, input: CredentialGroupInput) throws -> CredentialGroup {
        try ensureInitialized()
        let jsonData = try Self.encoder.encode(input)
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
        return try Self.decodeJSON(CredentialGroup.self, from: json)
    }

    func deleteCredentialGroup(id: String) throws {
        try ensureInitialized()
        let rc = id.withCString { idPtr in
            orbit_delete_credential_group(app, idPtr)
        }
        guard rc == 0 else { throw OrbitError.apiError(rc) }
    }

    private func runOffThread<T>(_ block: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try block()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func decodeDatabaseResponse<T: Decodable>(_ type: T.Type, rc: Int32, outJson: UnsafeMutablePointer<CChar>?) throws -> T {
        guard rc == 0 else {
            if let outJson {
                orbit_free_string(outJson)
            }
            throw OrbitError.apiErrorWithMessage(rc, lastErrorMessage())
        }
        guard let json = outJson else {
            throw OrbitError.apiErrorWithMessage(rc, lastErrorMessage())
        }
        defer { orbit_free_string(json) }
        return try Self.decodeJSON(type, from: json)
    }

    private func checkDatabaseResult(_ rc: Int32) throws {
        guard rc == 0 else {
            throw OrbitError.apiErrorWithMessage(rc, lastErrorMessage())
        }
    }

    // MARK: - Database

    func listDatabaseConnectionsAsync() async throws -> [DatabaseConnection] {
        try await runOffThread { try self.listDatabaseConnections() }
    }

    func listDatabaseConnections() throws -> [DatabaseConnection] {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = orbit_db_list_connections(app, &outJson)
        return try decodeDatabaseResponse([DatabaseConnection].self, rc: rc, outJson: outJson)
    }

    func addDatabaseConnectionAsync(input: DatabaseConnectionInput) async throws -> DatabaseConnection {
        try await runOffThread { try self.addDatabaseConnection(input: input) }
    }

    func addDatabaseConnection(input: DatabaseConnectionInput) throws -> DatabaseConnection {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(input)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = jsonString.withCString { inputPtr in
            orbit_db_add_connection(app, inputPtr, &outJson)
        }
        return try decodeDatabaseResponse(DatabaseConnection.self, rc: rc, outJson: outJson)
    }

    func updateDatabaseConnectionAsync(id: String, input: DatabaseConnectionInput) async throws -> DatabaseConnection {
        try await runOffThread { try self.updateDatabaseConnection(id: id, input: input) }
    }

    func updateDatabaseConnection(id: String, input: DatabaseConnectionInput) throws -> DatabaseConnection {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(input)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = id.withCString { idPtr in
            jsonString.withCString { inputPtr in
                orbit_db_update_connection(app, idPtr, inputPtr, &outJson)
            }
        }
        return try decodeDatabaseResponse(DatabaseConnection.self, rc: rc, outJson: outJson)
    }

    func deleteDatabaseConnectionAsync(id: String) async throws {
        try await runOffThread { try self.deleteDatabaseConnection(id: id) }
    }

    func deleteDatabaseConnection(id: String) throws {
        try ensureInitialized()
        let rc = id.withCString { idPtr in
            orbit_db_delete_connection(app, idPtr)
        }
        try checkDatabaseResult(rc)
    }

    func testDatabaseConnectionAsync(id: String, installSqlite: Bool) async throws -> DatabaseOperationResult {
        try await runOffThread { try self.testDatabaseConnection(id: id, installSqlite: installSqlite) }
    }

    func testDatabaseConnection(id: String, installSqlite: Bool) throws -> DatabaseOperationResult {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = id.withCString { idPtr in
            orbit_db_test_connection(app, idPtr, installSqlite, &outJson)
        }
        return try decodeDatabaseResponse(DatabaseOperationResult.self, rc: rc, outJson: outJson)
    }

    func listDatabaseSchemaAsync(connectionId: String) async throws -> DatabaseSchema {
        try await runOffThread { try self.listDatabaseSchema(connectionId: connectionId) }
    }

    func listDatabaseSchema(connectionId: String) throws -> DatabaseSchema {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = connectionId.withCString { connectionIdPtr in
            orbit_db_list_schema(app, connectionIdPtr, &outJson)
        }
        return try decodeDatabaseResponse(DatabaseSchema.self, rc: rc, outJson: outJson)
    }

    func executeDatabaseQueryAsync(connectionId: String, request: DatabaseQueryRequest) async throws -> DatabaseQueryResult {
        try await runOffThread { try self.executeDatabaseQuery(connectionId: connectionId, request: request) }
    }

    func executeDatabaseQuery(connectionId: String, request: DatabaseQueryRequest) throws -> DatabaseQueryResult {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(request)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = connectionId.withCString { connectionIdPtr in
            jsonString.withCString { requestPtr in
                orbit_db_execute(app, connectionIdPtr, requestPtr, &outJson)
            }
        }
        return try decodeDatabaseResponse(DatabaseQueryResult.self, rc: rc, outJson: outJson)
    }

    func backupDatabaseAsync(connectionId: String) async throws -> DatabaseOperationResult {
        try await runOffThread { try self.backupDatabase(connectionId: connectionId) }
    }

    func backupDatabase(connectionId: String) throws -> DatabaseOperationResult {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = connectionId.withCString { connectionIdPtr in
            orbit_db_backup(app, connectionIdPtr, &outJson)
        }
        return try decodeDatabaseResponse(DatabaseOperationResult.self, rc: rc, outJson: outJson)
    }

    func listDatabaseBackupRecordsAsync() async throws -> [DatabaseBackupRecord] {
        try await runOffThread { try self.listDatabaseBackupRecords() }
    }

    func listDatabaseBackupRecords() throws -> [DatabaseBackupRecord] {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = orbit_db_list_backup_records(app, &outJson)
        return try decodeDatabaseResponse([DatabaseBackupRecord].self, rc: rc, outJson: outJson)
    }

    func restoreDatabaseAsync(request: DatabaseRestoreRequest) async throws -> DatabaseOperationResult {
        try await runOffThread { try self.restoreDatabase(request: request) }
    }

    func restoreDatabase(request: DatabaseRestoreRequest) throws -> DatabaseOperationResult {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(request)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = jsonString.withCString { requestPtr in
            orbit_db_restore(app, requestPtr, &outJson)
        }
        return try decodeDatabaseResponse(DatabaseOperationResult.self, rc: rc, outJson: outJson)
    }

    func prepareDatabaseImportAsync(backupPath: String, targetConnectionId: String, mode: String) async throws -> DatabaseImportPlan {
        try await runOffThread {
            try self.prepareDatabaseImport(
                backupPath: backupPath,
                targetConnectionId: targetConnectionId,
                mode: mode
            )
        }
    }

    func prepareDatabaseImport(backupPath: String, targetConnectionId: String, mode: String) throws -> DatabaseImportPlan {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = backupPath.withCString { backupPathPtr in
            targetConnectionId.withCString { targetConnectionIdPtr in
                mode.withCString { modePtr in
                    orbit_db_prepare_import(app, backupPathPtr, targetConnectionIdPtr, modePtr, &outJson)
                }
            }
        }
        return try decodeDatabaseResponse(DatabaseImportPlan.self, rc: rc, outJson: outJson)
    }

    func runDatabaseImportAsync(request: DatabaseImportRequest) async throws -> DatabaseOperationResult {
        try await runOffThread { try self.runDatabaseImport(request: request) }
    }

    func runDatabaseImport(request: DatabaseImportRequest) throws -> DatabaseOperationResult {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(request)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = jsonString.withCString { requestPtr in
            orbit_db_run_import(app, requestPtr, &outJson)
        }
        return try decodeDatabaseResponse(DatabaseOperationResult.self, rc: rc, outJson: outJson)
    }

    // MARK: - SSH

    func connectSSHAsync(serverId: String) async throws -> String {
        try await runOffThread { try self.connectSSH(serverId: serverId) }
    }

    func spawnChannelAsync(existingSessionId: String) async throws -> String {
        try await runOffThread { try self.spawnChannel(existingSessionId: existingSessionId) }
    }

    func connectSSH(serverId: String) throws -> String {
        try ensureInitialized()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var outSessionId: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            orbit_connect_ssh(app, sidPtr, orbitDataCallback, orbitClosedCallback, selfPtr, &outSessionId)
        }
        guard rc == 0, let sessionId = outSessionId else {
            throw OrbitError.apiErrorWithMessage(rc, lastErrorMessage())
        }
        defer { orbit_free_string(sessionId) }
        return String(cString: sessionId)
    }

    func lastErrorMessage() -> String? {
        guard let app = app else { return nil }
        var outError: UnsafeMutablePointer<CChar>?
        let rc = orbit_get_last_error(app, &outError)
        guard rc == 0, let error = outError else { return nil }
        defer { orbit_free_string(error) }
        let message = String(cString: error)
        return message.isEmpty ? nil : message
    }

    func spawnChannel(existingSessionId: String) throws -> String {
        try ensureInitialized()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var outChannelId: UnsafeMutablePointer<CChar>?
        let rc = existingSessionId.withCString { sidPtr in
            orbit_spawn_channel(app, sidPtr, orbitDataCallback, orbitClosedCallback, selfPtr, &outChannelId)
        }
        guard rc == 0, let channelId = outChannelId else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(channelId) }
        return String(cString: channelId)
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

    func disconnectSSHAsync(sessionId: String) async throws {
        try await runOffThread { try self.disconnectSSH(sessionId: sessionId) }
    }

    func shutdownPool() {
        guard let app = self.app else { return }
        orbit_shutdown_pool(app)
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

    func sftpListFull(serverId: String, path: String) throws -> [FileEntry] {
        try ensureInitialized()
        print("[OrbitBridge] sftpListFull serverId=\(serverId) path=\(path)")
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            path.withCString { pathPtr in
                orbit_sftp_list_full(app, sidPtr, pathPtr, &outJson)
            }
        }
        guard rc == 0, let json = outJson else {
            print("[OrbitBridge] sftpListFull FAILED rc=\(rc)")
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        let result = try Self.decodeJSON([FileEntry].self, from: json)
        print("[OrbitBridge] sftpListFull OK path=\(path) entries=\(result.count)")
        return result
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

    func sftpUploadWithProgress(serverId: String, localPath: String, remotePath: String, progress: @escaping (UInt64, UInt64) -> Void) throws {
        try ensureInitialized()

        class ProgressContext {
            let callback: (UInt64, UInt64) -> Void
            init(callback: @escaping (UInt64, UInt64) -> Void) { self.callback = callback }
        }
        let ctx = ProgressContext(callback: progress)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()

        let rc = serverId.withCString { sidPtr in
            localPath.withCString { localPtr in
                remotePath.withCString { remotePtr in
                    orbit_sftp_upload(app, sidPtr, localPtr, remotePtr, { sidPtr, transferred, total, userdata in
                        guard let userdata = userdata else { return }
                        let ctx = Unmanaged<ProgressContext>.fromOpaque(userdata).takeUnretainedValue()
                        ctx.callback(transferred, total)
                    }, ctxPtr)
                }
            }
        }
        Unmanaged<ProgressContext>.fromOpaque(ctxPtr).release()
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

    func sftpReadTextFile(serverId: String, path: String, maxSize: UInt64 = 2 * 1024 * 1024) throws -> String {
        try ensureInitialized()
        print("[OrbitBridge] sftpReadTextFile serverId=\(serverId) path=\(path) maxSize=\(maxSize)")
        var outContent: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            path.withCString { pathPtr in
                orbit_sftp_read_text_file(app, sidPtr, pathPtr, maxSize, &outContent)
            }
        }
        guard rc == 0, let content = outContent else {
            print("[OrbitBridge] sftpReadTextFile FAILED rc=\(rc)")
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(content) }
        let result = String(cString: content)
        print("[OrbitBridge] sftpReadTextFile OK path=\(path) contentLen=\(result.count)")
        return result
    }

    func sftpWriteTextFile(serverId: String, path: String, content: String) throws {
        try ensureInitialized()
        print("[OrbitBridge] sftpWriteTextFile serverId=\(serverId) path=\(path) contentLen=\(content.count)")
        let rc = serverId.withCString { sidPtr in
            path.withCString { pathPtr in
                content.withCString { contentPtr in
                    orbit_sftp_write_text_file(app, sidPtr, pathPtr, contentPtr)
                }
            }
        }
        if rc != 0 {
            print("[OrbitBridge] sftpWriteTextFile FAILED rc=\(rc)")
            throw OrbitError.apiError(rc)
        }
        print("[OrbitBridge] sftpWriteTextFile OK path=\(path)")
    }

    func sftpRename(serverId: String, oldPath: String, newPath: String) throws {
        try ensureInitialized()
        print("[OrbitBridge] sftpRename serverId=\(serverId) old=\(oldPath) new=\(newPath)")
        let rc = serverId.withCString { sidPtr in
            oldPath.withCString { oldPtr in
                newPath.withCString { newPtr in
                    orbit_sftp_rename(app, sidPtr, oldPtr, newPtr)
                }
            }
        }
        if rc != 0 {
            print("[OrbitBridge] sftpRename FAILED rc=\(rc)")
            throw OrbitError.apiError(rc)
        }
        print("[OrbitBridge] sftpRename OK old=\(oldPath)")
    }

    // MARK: - Monitor

    func getServerStatsAsync(serverId: String) async throws -> ServerStats {
        try await runOffThread { try self.getServerStats(serverId: serverId) }
    }

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
        return try Self.decodeJSON(ServerStats.self, from: json)
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

    func getServerProcessesAsync(serverId: String) async throws -> [ServerProcess] {
        try await runOffThread { try self.getServerProcesses(serverId: serverId) }
    }

    func getServerProcesses(serverId: String) throws -> [ServerProcess] {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            orbit_get_server_processes(app, sidPtr, &outJson)
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try Self.decodeJSON([ServerProcess].self, from: json)
    }

    // MARK: - Docker

    func listDockerContainersAsync(serverId: String) async throws -> [DockerContainer] {
        try await runOffThread { try self.listDockerContainers(serverId: serverId) }
    }

    func listDockerContainers(serverId: String) throws -> [DockerContainer] {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            orbit_docker_list_containers(app, sidPtr, &outJson)
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try Self.decodeJSON([DockerContainer].self, from: json)
    }

    func getDockerStatsAsync(serverId: String) async throws -> [DockerContainerStats] {
        try await runOffThread { try self.getDockerStats(serverId: serverId) }
    }

    func getDockerStats(serverId: String) throws -> [DockerContainerStats] {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            orbit_docker_stats(app, sidPtr, &outJson)
        }
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return try Self.decodeJSON([DockerContainerStats].self, from: json)
    }

    func getDockerLogsAsync(serverId: String, containerId: String, tail: UInt32 = 200) async throws -> String {
        try await runOffThread { try self.getDockerLogs(serverId: serverId, containerId: containerId, tail: tail) }
    }

    func getDockerLogs(serverId: String, containerId: String, tail: UInt32 = 200) throws -> String {
        try ensureInitialized()
        var outLogs: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            containerId.withCString { cidPtr in
                orbit_docker_logs(app, sidPtr, cidPtr, tail, &outLogs)
            }
        }
        guard rc == 0, let logs = outLogs else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(logs) }
        return String(cString: logs)
    }

    @discardableResult
    func dockerActionAsync(serverId: String, containerId: String, action: String) async throws -> String {
        try await runOffThread { try self.dockerAction(serverId: serverId, containerId: containerId, action: action) }
    }

    @discardableResult
    func dockerAction(serverId: String, containerId: String, action: String) throws -> String {
        try ensureInitialized()
        var outOutput: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            containerId.withCString { cidPtr in
                action.withCString { actionPtr in
                    orbit_docker_action(app, sidPtr, cidPtr, actionPtr, &outOutput)
                }
            }
        }
        guard rc == 0, let output = outOutput else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(output) }
        return String(cString: output)
    }

    func exportConfig() throws -> String {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = orbit_export_config(app, &outJson)
        guard rc == 0, let json = outJson else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(json) }
        return String(cString: json)
    }

    func importConfig(jsonContent: String, strategy: Int32) throws -> Int32 {
        try ensureInitialized()
        var importedCount: Int32 = 0
        let rc = jsonContent.withCString { jsonPtr in
            orbit_import_config(app, jsonPtr, strategy, &importedCount)
        }
        guard rc == 0 else {
            throw OrbitError.apiError(rc)
        }
        return importedCount
    }

    @discardableResult
    func execCommand(serverId: String, command: String, timeoutMs: UInt32 = 30000) throws -> String {
        try ensureInitialized()
        var outOutput: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { sidPtr in
            command.withCString { cmdPtr in
                orbit_exec_command(app, sidPtr, cmdPtr, timeoutMs, &outOutput)
            }
        }
        guard rc == 0, let output = outOutput else {
            throw OrbitError.apiError(rc)
        }
        defer { orbit_free_string(output) }
        return String(cString: output)
    }

    @discardableResult
    func startPortForward(forwardingId: String, serverId: String, localPort: UInt16, remoteHost: String, remotePort: UInt16) throws -> UInt16 {
        try ensureInitialized()
        var actualPort: UInt16 = 0
        let rc = forwardingId.withCString { fidPtr in
            serverId.withCString { sidPtr in
                remoteHost.withCString { rhostPtr in
                    orbit_start_port_forward(app, fidPtr, sidPtr, localPort, rhostPtr, remotePort, &actualPort)
                }
            }
        }
        guard rc == 0 else {
            throw OrbitError.apiError(rc)
        }
        return actualPort
    }

    func stopPortForward(forwardingId: String) throws {
        try ensureInitialized()
        let rc = forwardingId.withCString { fidPtr in
            orbit_stop_port_forward(app, fidPtr)
        }
        guard rc == 0 else {
            throw OrbitError.apiError(rc)
        }
    }

    @discardableResult
    func startPortForwardAsync(forwardingId: String, serverId: String, localPort: UInt16, remoteHost: String, remotePort: UInt16) async throws -> UInt16 {
        try await runOffThread { try self.startPortForward(forwardingId: forwardingId, serverId: serverId, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort) }
    }

    func stopPortForwardAsync(forwardingId: String) async throws {
        try await runOffThread { try self.stopPortForward(forwardingId: forwardingId) }
    }
}

enum OrbitError: LocalizedError {
    case notInitialized
    case initializationFailed
    case apiError(Int32)
    case apiErrorWithMessage(Int32, String?)

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "OrbitApp not initialized"
        case .initializationFailed: return "Failed to initialize OrbitApp"
        case .apiError(let rc): return "API error: code \(rc)"
        case .apiErrorWithMessage(let rc, let message):
            if let message, !message.isEmpty {
                return "API error: code \(rc) - \(message)"
            }
            return "API error: code \(rc)"
        }
    }
}
