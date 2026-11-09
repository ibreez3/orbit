import Foundation

public struct AgentShellCommandResult: Equatable, Sendable {
    public var output: String
    public var exitCode: Int32

    public init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

public struct AgentShellSentinel: Sendable {
    public let uuid: String

    public init(uuid: String) {
        self.uuid = uuid
    }

    public func commandSuffix() -> String {
        "printf '\\n__ORBIT_DONE_\(uuid)__%s\\n' \"$?\""
    }

    public func consume(buffer: inout String) -> AgentShellCommandResult? {
        let markerPrefix = "__ORBIT_DONE_\(uuid)__"
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: "\n") {
            let line = buffer[lineStart..<newline]
            if line.hasPrefix(markerPrefix),
               let exitCode = Int32(line.dropFirst(markerPrefix.count)) {
                var output = String(buffer[..<lineStart])
                if output.hasSuffix("\n") {
                    output.removeLast()
                }
                buffer = String(buffer[buffer.index(after: newline)...])
                return AgentShellCommandResult(output: output, exitCode: exitCode)
            }
            lineStart = buffer.index(after: newline)
        }
        return nil
    }
}
