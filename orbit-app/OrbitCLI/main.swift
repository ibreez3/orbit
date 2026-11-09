import AgentKit
import Foundation

let client = AgentSocketClient(socketPath: AgentPaths.socketPath)
do {
    try client.connect(timeout: 1)
} catch {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    let appBundle = executable
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [appBundle.path]
    try? open.run()
    let deadline = Date().addingTimeInterval(10)
    var connected = false
    while Date() < deadline {
        if (try? client.connect(timeout: 1)) != nil {
            connected = true
            break
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    if !connected {
        FileHandle.standardError.write(Data("orbit-cli: Orbit is not running\n".utf8))
        exit(1)
    }
}

let sessions = AgentSessionFileStore(directory: AgentPaths.cliSessionsDirectory)
do {
    try AgentCLI.run(
        arguments: Array(CommandLine.arguments.dropFirst()),
        client: client,
        sessions: sessions,
        stdout: { print($0) },
        stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    )
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
