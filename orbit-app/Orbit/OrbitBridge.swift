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
    private static let maxPendingSSHSessions = 32
    private static let maxPendingSSHEventsPerSession = 256
    private static let maxPendingSSHDataBytesPerSession = 2 * 1024 * 1024
    private static let maxClosedSSHSessions = 64
    private static let maxIgnoredSSHSessions = 64

    private enum PendingSSHEvent {
        case data(Data)
        case closed
    }

    private struct PendingSSHEventBuffer {
        var events: [PendingSSHEvent] = []
        var dataBytes = 0
        var hasClosed = false
    }

    private final class SSHHandlerGeneration {
        var cancelled = false
    }

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
    private var pendingSSHEvents: [String: PendingSSHEventBuffer] = [:]
    private var pendingSSHSessionOrder: [String] = []
    private var drainingSSHSessionIds: Set<String> = []
    private var sshHandlerGenerations: [String: SSHHandlerGeneration] = [:]
    private var closedSSHSessionIds: Set<String> = []
    private var closedSSHSessionOrder: [String] = []
    private var ignoredSSHSessionIds: Set<String> = []
    private var ignoredSSHSessionOrder: [String] = []

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
        let databaseURL = Self.databaseURL(
            applicationSupportDirectory: appSupport,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbPath = databaseURL.path
        app = dbPath.withCString { path in
            orbit_app_new(path)
        }
        guard app != nil else {
            throw OrbitError.initializationFailed
        }
    }

    static func databaseURL(
        applicationSupportDirectory: URL,
        temporaryDirectory: URL,
        environment: [String: String],
        processIdentifier: Int32
    ) -> URL {
        if let override = environment["ORBIT_DB_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override)
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return temporaryDirectory
                .appendingPathComponent("orbit-tests-\(processIdentifier)", isDirectory: true)
                .appendingPathComponent("orbit.db")
        }
        return applicationSupportDirectory
            .appendingPathComponent("orbit", isDirectory: true)
            .appendingPathComponent("orbit.db")
    }

    deinit {
        if let app = app {
            orbit_app_free(app)
        }
    }

    func handleSSHData(sessionId: String, data: Data) {
        handlersLock.lock()
        guard !ignoredSSHSessionIds.contains(sessionId),
              !closedSSHSessionIds.contains(sessionId) else {
            handlersLock.unlock()
            return
        }
        if drainingSSHSessionIds.contains(sessionId) || sshDataHandlers[sessionId] == nil {
            bufferSSHEventLocked(.data(data), sessionId: sessionId)
            handlersLock.unlock()
            return
        }
        let handler = sshDataHandlers[sessionId]
        handlersLock.unlock()
        handler?(data)
    }

    func handleSSHClosed(sessionId: String) {
        handlersLock.lock()
        guard !ignoredSSHSessionIds.contains(sessionId),
              recordSSHClosedLocked(sessionId) else {
            handlersLock.unlock()
            return
        }
        if drainingSSHSessionIds.contains(sessionId) || sshClosedHandlers[sessionId] == nil {
            bufferSSHEventLocked(.closed, sessionId: sessionId)
            handlersLock.unlock()
            return
        }
        let handler = sshClosedHandlers[sessionId]
        handlersLock.unlock()
        handler?()
    }

    private func recordSSHClosedLocked(_ sessionId: String) -> Bool {
        guard closedSSHSessionIds.insert(sessionId).inserted else { return false }
        closedSSHSessionOrder.append(sessionId)
        if closedSSHSessionOrder.count > Self.maxClosedSSHSessions {
            let staleSessionId = closedSSHSessionOrder.removeFirst()
            closedSSHSessionIds.remove(staleSessionId)
        }
        return true
    }

    private func bufferSSHEventLocked(_ event: PendingSSHEvent, sessionId: String) {
        if pendingSSHEvents[sessionId] == nil {
            if pendingSSHEvents.count >= Self.maxPendingSSHSessions,
               let staleSessionId = pendingSSHSessionOrder.first(where: {
                   !drainingSSHSessionIds.contains($0)
               }) ?? pendingSSHSessionOrder.first {
                pendingSSHEvents.removeValue(forKey: staleSessionId)
                pendingSSHSessionOrder.removeAll { $0 == staleSessionId }
            }
            pendingSSHEvents[sessionId] = PendingSSHEventBuffer()
            pendingSSHSessionOrder.append(sessionId)
        }

        guard var buffer = pendingSSHEvents[sessionId] else { return }
        switch event {
        case .data(let data):
            guard buffer.events.count < Self.maxPendingSSHEventsPerSession else { return }
            let availableBytes = Self.maxPendingSSHDataBytesPerSession - buffer.dataBytes
            guard availableBytes > 0 else { return }
            let boundedData = data.count <= availableBytes ? data : Data(data.prefix(availableBytes))
            buffer.events.append(.data(boundedData))
            buffer.dataBytes += boundedData.count
        case .closed:
            guard !buffer.hasClosed else { return }
            if buffer.events.count >= Self.maxPendingSSHEventsPerSession,
               let lastDataIndex = buffer.events.lastIndex(where: {
                   if case .data = $0 { return true }
                   return false
               }) {
                if case .data(let data) = buffer.events.remove(at: lastDataIndex) {
                    buffer.dataBytes -= data.count
                }
            }
            buffer.events.append(.closed)
            buffer.hasClosed = true
        }
        pendingSSHEvents[sessionId] = buffer
    }

    func handleProgress(serverId: String, transferred: UInt64, total: UInt64) {
        handlersLock.lock()
        let handler = progressHandlers[serverId]
        handlersLock.unlock()
        handler?(transferred, total)
    }

    func removeSSHHandlers(sessionId: String) {
        handlersLock.lock()
        if let generation = sshHandlerGenerations.removeValue(forKey: sessionId) {
            generation.cancelled = true
        }
        sshDataHandlers.removeValue(forKey: sessionId)
        sshClosedHandlers.removeValue(forKey: sessionId)
        pendingSSHEvents.removeValue(forKey: sessionId)
        pendingSSHSessionOrder.removeAll { $0 == sessionId }
        drainingSSHSessionIds.remove(sessionId)
        closedSSHSessionIds.remove(sessionId)
        closedSSHSessionOrder.removeAll { $0 == sessionId }
        if ignoredSSHSessionIds.insert(sessionId).inserted {
            ignoredSSHSessionOrder.append(sessionId)
            if ignoredSSHSessionOrder.count > Self.maxIgnoredSSHSessions {
                let staleSessionId = ignoredSSHSessionOrder.removeFirst()
                ignoredSSHSessionIds.remove(staleSessionId)
            }
        }
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
        ignoredSSHSessionIds.remove(sessionId)
        ignoredSSHSessionOrder.removeAll { $0 == sessionId }
        let generation: SSHHandlerGeneration
        if let currentGeneration = sshHandlerGenerations[sessionId],
           !currentGeneration.cancelled {
            generation = currentGeneration
        } else {
            generation = SSHHandlerGeneration()
            sshHandlerGenerations[sessionId] = generation
        }
        sshDataHandlers[sessionId] = dataHandler
        sshClosedHandlers[sessionId] = closedHandler
        let shouldDrain = pendingSSHEvents[sessionId] != nil
            && !drainingSSHSessionIds.contains(sessionId)
        if shouldDrain {
            drainingSSHSessionIds.insert(sessionId)
        }
        handlersLock.unlock()
        if shouldDrain {
            drainPendingSSHEvents(sessionId: sessionId, generation: generation)
        }
    }

    private func drainPendingSSHEvents(sessionId: String, generation: SSHHandlerGeneration) {
        while true {
            handlersLock.lock()
            guard let currentGeneration = sshHandlerGenerations[sessionId],
                  currentGeneration === generation,
                  !generation.cancelled,
                  sshDataHandlers[sessionId] != nil,
                  sshClosedHandlers[sessionId] != nil else {
                pendingSSHEvents.removeValue(forKey: sessionId)
                pendingSSHSessionOrder.removeAll { $0 == sessionId }
                if sshHandlerGenerations[sessionId] == nil
                    || sshHandlerGenerations[sessionId] === generation {
                    drainingSSHSessionIds.remove(sessionId)
                }
                handlersLock.unlock()
                return
            }
            guard let buffer = pendingSSHEvents.removeValue(forKey: sessionId),
                  !buffer.events.isEmpty else {
                pendingSSHSessionOrder.removeAll { $0 == sessionId }
                drainingSSHSessionIds.remove(sessionId)
                handlersLock.unlock()
                return
            }
            pendingSSHSessionOrder.removeAll { $0 == sessionId }
            handlersLock.unlock()

            for event in buffer.events {
                handlersLock.lock()
                guard let currentGeneration = sshHandlerGenerations[sessionId],
                      currentGeneration === generation,
                      !generation.cancelled else {
                    handlersLock.unlock()
                    return
                }
                switch event {
                case .data(let data):
                    let handler = sshDataHandlers[sessionId]
                    handlersLock.unlock()
                    guard let handler else { return }
                    handler(data)
                case .closed:
                    let handler = sshClosedHandlers[sessionId]
                    handlersLock.unlock()
                    guard let handler else { return }
                    handler()
                }
            }
        }
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

    func listServerOrganizationAsync() async throws -> ServerOrganizationSnapshot {
        try await runOffThread { try self.listServerOrganization() }
    }

    func listServerOrganization() throws -> ServerOrganizationSnapshot {
        try ensureInitialized()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = orbit_list_server_organization(app, &outJson)
        return try decodeWorkspaceResponse(
            ServerOrganizationSnapshot.self,
            rc: rc,
            outJson: outJson
        )
    }

    func createServerFolderAsync(input: FolderInput) async throws -> ServerFolder {
        try await runOffThread { try self.createServerFolder(input: input) }
    }

    func createServerFolder(input: FolderInput) throws -> ServerFolder {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(input)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = jsonString.withCString { inputPtr in
            orbit_create_server_folder(app, inputPtr, &outJson)
        }
        return try decodeWorkspaceResponse(ServerFolder.self, rc: rc, outJson: outJson)
    }

    func renameServerFolderAsync(id: String, input: FolderInput) async throws -> ServerFolder {
        try await runOffThread { try self.renameServerFolder(id: id, input: input) }
    }

    func renameServerFolder(id: String, input: FolderInput) throws -> ServerFolder {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(input)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = id.withCString { idPtr in
            jsonString.withCString { inputPtr in
                orbit_rename_server_folder(app, idPtr, inputPtr, &outJson)
            }
        }
        return try decodeWorkspaceResponse(ServerFolder.self, rc: rc, outJson: outJson)
    }

    func moveServerFolderAsync(id: String, input: FolderMoveInput) async throws -> ServerFolder {
        try await runOffThread { try self.moveServerFolder(id: id, input: input) }
    }

    func moveServerFolder(id: String, input: FolderMoveInput) throws -> ServerFolder {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(input)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = id.withCString { idPtr in
            jsonString.withCString { inputPtr in
                orbit_move_server_folder(app, idPtr, inputPtr, &outJson)
            }
        }
        return try decodeWorkspaceResponse(ServerFolder.self, rc: rc, outJson: outJson)
    }

    func deleteServerFolderAsync(id: String, input: FolderDeleteInput) async throws {
        try await runOffThread { try self.deleteServerFolder(id: id, input: input) }
    }

    func deleteServerFolder(id: String, input: FolderDeleteInput) throws {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(input)
        let rc = id.withCString { idPtr in
            jsonString.withCString { inputPtr in
                orbit_delete_server_folder(app, idPtr, inputPtr)
            }
        }
        try checkWorkspaceResult(rc)
    }

    func createServerTagAsync(name: String) async throws -> ServerTag {
        try await runOffThread { try self.createServerTag(name: name) }
    }

    func createServerTag(name: String) throws -> ServerTag {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(name)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = jsonString.withCString { inputPtr in
            orbit_create_server_tag(app, inputPtr, &outJson)
        }
        return try decodeWorkspaceResponse(ServerTag.self, rc: rc, outJson: outJson)
    }

    func deleteServerTagAsync(id: String) async throws {
        try await runOffThread { try self.deleteServerTag(id: id) }
    }

    func deleteServerTag(id: String) throws {
        try ensureInitialized()
        let rc = id.withCString { idPtr in
            orbit_delete_server_tag(app, idPtr)
        }
        try checkWorkspaceResult(rc)
    }

    func setServerTagsAsync(serverId: String, tagIds: [String]) async throws {
        try await runOffThread { try self.setServerTags(serverId: serverId, tagIds: tagIds) }
    }

    func setServerTags(serverId: String, tagIds: [String]) throws {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(ServerTagsInput(tag_ids: tagIds))
        let rc = serverId.withCString { serverIdPtr in
            jsonString.withCString { inputPtr in
                orbit_set_server_tags(app, serverIdPtr, inputPtr)
            }
        }
        try checkWorkspaceResult(rc)
    }

    func moveServerAsync(serverId: String, folderId: String?) async throws {
        try await runOffThread { try self.moveServer(serverId: serverId, folderId: folderId) }
    }

    func moveServer(serverId: String, folderId: String?) throws {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(ServerMoveInput(folder_id: folderId))
        let rc = serverId.withCString { serverIdPtr in
            jsonString.withCString { inputPtr in
                orbit_move_server(app, serverIdPtr, inputPtr)
            }
        }
        try checkWorkspaceResult(rc)
    }

    func setServerPinAsync(
        serverId: String,
        isPinned: Bool,
        pinOrder: Int64?
    ) async throws -> Server {
        try await runOffThread {
            try self.setServerPin(serverId: serverId, isPinned: isPinned, pinOrder: pinOrder)
        }
    }

    func setServerPin(serverId: String, isPinned: Bool, pinOrder: Int64?) throws -> Server {
        try ensureInitialized()
        let input = ServerPinInput(is_pinned: isPinned, pin_order: pinOrder)
        let jsonString = try Self.encodeJSONString(input)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = serverId.withCString { serverIdPtr in
            jsonString.withCString { inputPtr in
                orbit_set_server_pin(app, serverIdPtr, inputPtr, &outJson)
            }
        }
        return try decodeWorkspaceResponse(Server.self, rc: rc, outJson: outJson)
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

    private func decodeWorkspaceResponse<T: Decodable>(
        _ type: T.Type,
        rc: Int32,
        outJson: UnsafeMutablePointer<CChar>?
    ) throws -> T {
        guard rc == 0, let json = outJson else {
            if let outJson {
                orbit_free_string(outJson)
            }
            throw OrbitError.apiErrorWithMessage(rc, lastErrorMessage())
        }
        defer { orbit_free_string(json) }
        return try Self.decodeJSON(type, from: json)
    }

    private func checkWorkspaceResult(_ rc: Int32) throws {
        guard rc == 0 else {
            throw OrbitError.apiErrorWithMessage(rc, lastErrorMessage())
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

    func connectTemporarySSHAsync(input: TemporaryConnectionInput) async throws -> String {
        try await runOffThread { try self.connectTemporarySSH(input: input) }
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

    func connectTemporarySSH(input: TemporaryConnectionInput) throws -> String {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(input)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var outSessionId: UnsafeMutablePointer<CChar>?
        let rc = jsonString.withCString { inputPtr in
            orbit_connect_ssh_temporary(
                app,
                inputPtr,
                orbitDataCallback,
                orbitClosedCallback,
                selfPtr,
                &outSessionId
            )
        }
        guard rc == 0, let sessionId = outSessionId else {
            if let outSessionId {
                orbit_free_string(outSessionId)
            }
            throw OrbitError.apiErrorWithMessage(rc, lastErrorMessage())
        }
        defer { orbit_free_string(sessionId) }
        return String(cString: sessionId)
    }

    func promoteTemporaryServerAsync(
        sessionId: String,
        input: PromoteTemporaryServerInput
    ) async throws -> Server {
        try await runOffThread {
            try self.promoteTemporaryServer(sessionId: sessionId, input: input)
        }
    }

    func promoteTemporaryServer(
        sessionId: String,
        input: PromoteTemporaryServerInput
    ) throws -> Server {
        try ensureInitialized()
        let jsonString = try Self.encodeJSONString(input)
        var outJson: UnsafeMutablePointer<CChar>?
        let rc = sessionId.withCString { sessionIdPtr in
            jsonString.withCString { inputPtr in
                orbit_promote_temporary_server(app, sessionIdPtr, inputPtr, &outJson)
            }
        }
        return try decodeWorkspaceResponse(Server.self, rc: rc, outJson: outJson)
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

extension OrbitBridge: ServerWorkspaceBridge {}

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
                return message
            }
            return "API error: code \(rc)"
        }
    }
}
