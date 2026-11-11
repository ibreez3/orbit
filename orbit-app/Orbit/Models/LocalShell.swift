import Foundation
import Darwin

class LocalShell {
    private let stateLock = NSLock()
    private var masterFd: Int32 = -1
    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var cleanedUp = false
    private var resizeDeduplicator = TerminalResizeDeduplicator()

    private(set) var isRunning = false

    var onData: ((Data) -> Void)?
    var onClosed: (() -> Void)?

    func start(cols: UInt16 = 80, rows: UInt16 = 24) {
        guard !isRunning else { return }

        // Create PTY master/slave pair manually
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else {
            print("[LocalShell] posix_openpt failed")
            return
        }
        grantpt(master)
        unlockpt(master)

        guard let slavePath = ptsname(master) else {
            close(master)
            return
        }
        let slave = open(slavePath, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            return
        }

        // Set initial window size on slave
        var ws = winsize()
        ws.ws_col = cols
        ws.ws_row = rows
        let initialResizeSucceeded = ioctl(slave, TIOCSWINSZ, &ws) == 0

        // Use posix_spawn instead of forkpty (safe in multi-threaded process)
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addclose(&fileActions, slave)

        // Set working directory to user's home
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        posix_spawn_file_actions_addchdir_np(&fileActions, homeDir)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellArg = strdup(shell)!
        let dashL = strdup("-l")!
        var args: [UnsafeMutablePointer<CChar>?] = [shellArg, dashL, nil]

        // Build environment with TERM=xterm-256color and ensure HOME is set
        var envList: [UnsafeMutablePointer<CChar>?] = []
        var termSet = false
        var homeSet = false
        var ptr = environ
        while let entry = ptr.pointee {
            let str = String(cString: entry)
            if str.hasPrefix("TERM=") {
                envList.append(strdup("TERM=xterm-256color"))
                termSet = true
            } else if str.hasPrefix("HOME=") {
                envList.append(strdup("HOME=\(homeDir)"))
                homeSet = true
            } else {
                envList.append(strdup(entry))
            }
            ptr += 1
        }
        if !termSet {
            envList.append(strdup("TERM=xterm-256color"))
        }
        if !homeSet {
            envList.append(strdup("HOME=\(homeDir)"))
        }
        envList.append(nil)

        var childPid: pid_t = 0
        let result = posix_spawn(&childPid, shell, &fileActions, nil, &args, &envList)

        free(shellArg)
        free(dashL)
        for ptr in envList { if let p = ptr { free(p) } }
        posix_spawn_file_actions_destroy(&fileActions)
        close(slave)

        guard result == 0 else {
            close(master)
            print("[LocalShell] posix_spawn failed: \(result)")
            return
        }

        stateLock.lock()
        if initialResizeSucceeded {
            resizeDeduplicator.record(sessionId: "local", cols: Int(cols), rows: Int(rows))
        }
        self.masterFd = master
        self.pid = childPid
        self.isRunning = true
        stateLock.unlock()

        // Async read from PTY master
        let fd = master
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let fd = self.masterFd
            self.stateLock.unlock()
            guard fd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[..<count])
                self.onData?(data)
            } else if count == 0 || errno != EAGAIN {
                self.cleanup()
            }
        }
        source.setCancelHandler { [weak self] in
            self?.cleanup()
        }
        source.resume()
        readSource = source
    }

    func write(_ data: Data) {
        stateLock.lock()
        let fd = masterFd
        stateLock.unlock()
        guard fd >= 0 else { return }
        Darwin.write(fd, [UInt8](data), data.count)
    }

    /// Returns true when the size is known to be applied (including an
    /// already-recorded no-op), false when the ioctl failed and a retry is
    /// needed.
    @discardableResult
    func resize(cols: UInt16, rows: UInt16) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard masterFd >= 0 else { return false }
        guard resizeDeduplicator.needsResize(sessionId: "local", cols: Int(cols), rows: Int(rows)) else {
            return true
        }
        var ws = winsize()
        ws.ws_col = cols
        ws.ws_row = rows
        if ioctl(masterFd, TIOCSWINSZ, &ws) == 0 {
            resizeDeduplicator.record(sessionId: "local", cols: Int(cols), rows: Int(rows))
            return true
        }
        return false
    }

    /// Terminates the shell without emitting `onClosed`. Used when a pane or
    /// tab is closed, where the UI has already decided the session is gone.
    func stop() {
        stateLock.lock()
        guard !cleanedUp else {
            stateLock.unlock()
            return
        }
        cleanedUp = true
        isRunning = false
        let fd = masterFd
        masterFd = -1
        let childPid = pid
        pid = 0
        let source = readSource
        readSource = nil
        stateLock.unlock()

        source?.cancel()
        if fd >= 0 {
            close(fd)
        }
        if childPid > 0 {
            kill(childPid, SIGTERM)
        }
    }

    private func cleanup() {
        stateLock.lock()
        guard !cleanedUp else {
            stateLock.unlock()
            return
        }
        cleanedUp = true
        isRunning = false
        let fd = masterFd
        masterFd = -1
        readSource = nil
        stateLock.unlock()

        if fd >= 0 {
            close(fd)
        }
        DispatchQueue.main.async { [weak self] in
            self?.onClosed?()
        }
    }

    deinit {
        stop()
    }
}
