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
        FileHandle.standardError.write(Data("orbit-mcp: Orbit is not running\n".utf8))
        exit(1)
    }
}

let core = MCPBridgeCore(client: client)
var buffer = Data()
let input = FileHandle.standardInput
let output = FileHandle.standardOutput

while true {
    let chunk = input.readData(ofLength: 4096)
    if chunk.isEmpty { break }
    buffer.append(chunk)
    while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[..<newline]
        buffer.removeSubrange(...newline)
        guard !line.isEmpty,
              let request = try? JSONDecoder().decode(MCPRequest.self, from: Data(line)) else {
            continue
        }
        guard let response = core.handle(request) else { continue }
        guard let data = try? JSONEncoder().encode(response) else { continue }
        output.write(data)
        output.write(Data([0x0A]))
    }
}
