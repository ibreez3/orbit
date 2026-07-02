import Foundation
import Darwin

class LocalShell {
    private var masterFd: Int32 = -1
    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var cleanedUp = false

    var onData: ((Data) -> Void)?
    var onClosed: (() -> Void)?

    func start(cols: UInt16 = 80, rows: UInt16 = 24) {
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
        _ = ioctl(slave, TIOCSWINSZ, &ws)

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

        self.masterFd = master
        self.pid = childPid

        // Async read from PTY master
        let fd = master
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self = self, self.masterFd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(self.masterFd, &buffer, buffer.count)
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
        guard masterFd >= 0 else { return }
        Darwin.write(masterFd, [UInt8](data), data.count)
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFd >= 0 else { return }
        var ws = winsize()
        ws.ws_col = cols
        ws.ws_row = rows
        _ = ioctl(masterFd, TIOCSWINSZ, &ws)
    }

    private func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        readSource = nil
        if masterFd >= 0 {
            close(masterFd)
            masterFd = -1
        }
        DispatchQueue.main.async { [weak self] in
            self?.onClosed?()
        }
    }

    deinit {
        readSource?.cancel()
        if pid > 0 {
            kill(pid, SIGTERM)
        }
    }
}
