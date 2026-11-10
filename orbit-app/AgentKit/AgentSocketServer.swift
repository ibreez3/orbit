import Darwin
import Foundation

public enum AgentSocketError: LocalizedError, Equatable {
    case pathTooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let maximum):
            return "Unix socket path must be shorter than \(maximum) bytes"
        }
    }
}

public final class AgentSocketServer {
    public typealias Handler = (AgentRequest, @escaping (AgentResponse) -> Void) -> Void

    public var onRequest: Handler?

    private let socketPath: String
    private let acceptQueue = DispatchQueue(label: "com.orbit.agent.socket.accept")
    private let connectionsLock = NSLock()
    private var connections: Set<Connection> = []
    private var listeningFD: Int32 = -1
    private var running = false
    private var acceptThread: Thread?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard !running else { return }
        let maximumPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard socketPath.utf8.count < maximumPathBytes else {
            throw AgentSocketError.pathTooLong(maximumPathBytes - 1)
        }
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError()
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let count = min(pathBytes.count, raw.count - 1)
            raw.copyBytes(from: pathBytes.prefix(count))
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw posixError()
        }
        guard chmod(socketPath, 0o600) == 0 else {
            close(fd)
            unlink(socketPath)
            throw posixError()
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(socketPath)
            throw posixError()
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listeningFD = fd
        running = true
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "com.orbit.agent.socket.accept"
        acceptThread = thread
        thread.start()
    }

    public func stop() {
        running = false
        if listeningFD >= 0 {
            shutdown(listeningFD, SHUT_RDWR)
            close(listeningFD)
            listeningFD = -1
        }
        unlink(socketPath)
        connectionsLock.lock()
        let active = connections
        connections.removeAll()
        connectionsLock.unlock()
        for connection in active {
            connection.close()
        }
    }

    private func acceptLoop() {
        while running {
            let client = accept(listeningFD, nil, nil)
            if client < 0 {
                if !running { break }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(10_000)
                    continue
                }
                usleep(10_000)
                continue
            }
            let clientFlags = fcntl(client, F_GETFL, 0)
            if clientFlags >= 0 {
                _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
            }
            let connection = Connection(fd: client)
            connection.onRequest = onRequest
            connection.onClose = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.connectionsLock.lock()
                self.connections.remove(connection)
                self.connectionsLock.unlock()
            }
            connectionsLock.lock()
            connections.insert(connection)
            connectionsLock.unlock()
            connection.start()
        }
    }

    private func posixError() -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
        )
    }

    private final class Connection: Hashable {
        var onRequest: Handler?
        var onClose: (() -> Void)?

        private let fd: Int32
        private let readQueue = DispatchQueue(label: "com.orbit.agent.socket.connection.read")
        private let writeQueue = DispatchQueue(label: "com.orbit.agent.socket.connection.write")
        private let stateLock = NSLock()
        private var open = true
        private var buffer = Data()

        init(fd: Int32) {
            self.fd = fd
        }

        static func == (lhs: Connection, rhs: Connection) -> Bool {
            lhs === rhs
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }

        func start() {
            readQueue.async { [weak self] in
                self?.readLoop()
            }
        }

        func close() {
            stateLock.lock()
            guard open else {
                stateLock.unlock()
                return
            }
            open = false
            stateLock.unlock()
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            onClose?()
        }

        private func readLoop() {
            var chunk = [UInt8](repeating: 0, count: 8192)
            while isOpen {
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count <= 0 {
                    break
                }
                buffer.append(chunk, count: count)
                drainLines()
            }
            close()
        }

        private func drainLines() {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let request = try? JSONDecoder().decode(AgentRequest.self, from: Data(line)) else {
                    continue
                }
                guard let onRequest else { continue }
                onRequest(request) { [weak self] response in
                    self?.send(response)
                }
            }
        }

        private func send(_ response: AgentResponse) {
            guard let data = try? JSONEncoder().encode(response) else { return }
            var line = data
            line.append(0x0A)
            writeQueue.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let isOpen = self.open
                self.stateLock.unlock()
                guard isOpen else { return }
                line.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.write(
                            self.fd,
                            base.advanced(by: offset),
                            raw.count - offset
                        )
                        if written <= 0 { return }
                        offset += written
                    }
                }
            }
        }

        private var isOpen: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return open
        }
    }
}
