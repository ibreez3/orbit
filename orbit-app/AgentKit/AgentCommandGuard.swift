import Foundation

public enum AgentGuardDecision: Equatable, Sendable {
    case allowRead
    case requireWrite(reason: String)
}

public enum AgentCommandGuard {
    public static func evaluate(command: String, declaredMode: AgentExecMode) -> AgentGuardDecision {
        if declaredMode == .write {
            return .requireWrite(reason: "The agent declared a write command")
        }
        if hasUnquotedCommandSubstitution(command) {
            return .requireWrite(reason: "Command substitution cannot be safely classified")
        }
        for segment in splitSegments(command) {
            if let reason = inspect(segment) {
                return .requireWrite(reason: reason)
            }
        }
        return .allowRead
    }

    private static let mutatingCommands: Set<String> = [
        "rm", "rmdir", "mv", "cp", "install", "touch", "mkdir", "ln",
        "chmod", "chown", "chgrp", "truncate", "dd", "mkfs", "mount", "umount",
        "shutdown", "reboot", "halt", "poweroff", "kill", "pkill", "killall",
        "tee", "eval", "xargs", "env", "sudo", "source", "."
    ]

    private static func inspect(_ segment: String) -> String? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if hasUnquotedRedirection(trimmed) {
            return "Command writes through a shell redirection"
        }

        var tokens = words(trimmed)
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
            tokens.removeFirst()
        }
        guard let rawCommand = tokens.first else { return nil }
        let command = (rawCommand as NSString).lastPathComponent.lowercased()
        let arguments = Array(tokens.dropFirst())

        if ["timeout", "nice", "nohup", "command", "exec", "time", "builtin", "busybox"].contains(command) {
            guard let inner = wrapperInner(command: command, arguments: arguments),
                  !inner.isEmpty else {
                return nil
            }
            return inspect(inner.joined(separator: " "))
        }

        if mutatingCommands.contains(command) {
            return "\(command) is a write command"
        }
        if command == "sed" || command == "perl" {
            if arguments.contains(where: { $0 == "-i" || $0.hasPrefix("--in-place") }) {
                return "\(command) writes files in place"
            }
        }
        if command == "bash" || command == "sh" || command == "zsh" || command == "fish" {
            if arguments.contains("-c") {
                return "A nested shell command cannot be safely classified"
            }
        }
        if ["python", "python3", "node", "perl", "ruby"].contains(command),
           arguments.contains(where: { $0 == "-c" || $0 == "-e" }) {
            return "Inline interpreter code cannot be safely classified"
        }
        if command == "git" {
            let subcommand = arguments.first?.lowercased() ?? ""
            let readOnly: Set<String> = [
                "status", "log", "diff", "show", "blame", "grep", "ls-files",
                "rev-parse", "remote", "branch"
            ]
            if !readOnly.contains(subcommand) ||
                arguments.contains(where: { $0 == "-d" || $0 == "-D" || $0 == "add" || $0 == "remove" || $0 == "set-url" }) {
                return "git \(subcommand) is a write operation"
            }
        }
        if command == "systemctl" {
            let subcommand = arguments.first?.lowercased() ?? ""
            let readOnly = ["status", "show", "is-active", "is-enabled", "cat"]
            if !readOnly.contains(subcommand) && !subcommand.hasPrefix("list-") {
                return "systemctl \(subcommand) may change service state"
            }
        }
        if command == "service" {
            if arguments.first?.lowercased() != "status" {
                return "service may change service state"
            }
        }
        if ["apt", "apt-get", "yum", "dnf", "pacman", "brew"].contains(command) {
            let subcommand = arguments.first?.lowercased() ?? ""
            if !["list", "search", "show", "info", "--version"].contains(subcommand) {
                return "\(command) \(subcommand) may modify packages"
            }
        }
        if ["pip", "pip3", "npm", "yarn"].contains(command) {
            let subcommand = arguments.first?.lowercased() ?? ""
            if !["list", "show", "freeze", "ls", "--version"].contains(subcommand) {
                return "\(command) \(subcommand) may modify packages"
            }
        }
        if command == "find" && arguments.contains(where: { $0 == "-delete" || $0 == "-exec" || $0 == "-execdir" }) {
            return "find with -delete or -exec is a write operation"
        }
        if (command == "curl" || command == "wget") &&
            arguments.contains(where: { $0 == "-o" || $0 == "-O" || $0.hasPrefix("--output") }) {
            return "\(command) writes a file"
        }
        if command == "docker" {
            return inspectDocker(arguments)
        }
        return nil
    }

    private static func inspectDocker(_ arguments: [String]) -> String? {
        guard let subcommandIndex = arguments.firstIndex(where: { !$0.hasPrefix("-") }) else {
            return nil
        }
        let subcommand = arguments[subcommandIndex].lowercased()
        let rest = Array(arguments.dropFirst(subcommandIndex + 1))
        switch subcommand {
        case "logs", "ps", "stats", "inspect", "version", "info", "top", "port", "diff", "images":
            return nil
        case "image", "container", "volume", "network":
            guard let action = rest.first?.lowercased() else { return nil }
            if ["ls", "list", "inspect", "ps"].contains(action) {
                return nil
            }
            return "docker \(subcommand) \(action) may modify state"
        case "system":
            if rest.first?.lowercased() == "df" {
                return nil
            }
            return "docker system may modify state"
        case "exec":
            guard let parsed = parseDockerExec(rest) else {
                return "docker exec requires a container and command"
            }
            if parsed.interactive {
                return "Interactive docker exec requires write approval"
            }
            guard !parsed.inner.isEmpty else {
                return "docker exec requires an inner command"
            }
            return inspect(parsed.inner.joined(separator: " "))
        default:
            return "docker \(subcommand) may modify container state"
        }
    }

    private static func splitSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote,
                   command.index(before: index) != command.startIndex,
                   command[command.index(before: index)] != "\\" {
                    quote = nil
                }
                index = command.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
                index = command.index(after: index)
                continue
            }
            if character == ";" || character == "\n" {
                segments.append(current)
                current = ""
                index = command.index(after: index)
                continue
            }
            if character == "&" {
                let next = command.index(after: index)
                let previousIsRedirect = index > command.startIndex
                    && command[command.index(before: index)] == ">"
                let nextIsRedirect = next < command.endIndex && command[next] == ">"
                if previousIsRedirect || nextIsRedirect {
                    current.append(character)
                    index = next
                    continue
                }
                if next < command.endIndex, command[next] == "&" {
                    segments.append(current)
                    current = ""
                    index = command.index(after: next)
                } else {
                    segments.append(current)
                    current = ""
                    index = next
                }
                continue
            }
            if character == "|" {
                let next = command.index(after: index)
                if next < command.endIndex, command[next] == "|" {
                    segments.append(current)
                    current = ""
                    index = command.index(after: next)
                    continue
                }
                segments.append(current)
                current = ""
                index = command.index(after: index)
                continue
            }
            current.append(character)
            index = command.index(after: index)
        }
        segments.append(current)
        return segments
    }

    private static let dockerExecValueOptions: Set<String> = [
        "-u", "--user", "-e", "--env", "--env-file",
        "-w", "--workdir", "--detach-keys"
    ]

    private static func parseDockerExec(
        _ arguments: [String]
    ) -> (interactive: Bool, container: String, inner: [String])? {
        var index = 0
        var interactive = false
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-"), token != "-" else { break }

            let optionName = token
                .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? token
            if optionName == "-i" || optionName == "--interactive"
                || optionName == "-t" || optionName == "--tty" {
                interactive = true
            }
            if optionName.hasPrefix("-"), !optionName.hasPrefix("--"),
               optionName.dropFirst().contains(where: { $0 == "i" || $0 == "t" }) {
                interactive = true
            }

            if dockerExecValueOptions.contains(optionName) && !token.contains("=") {
                index += 2
            } else {
                index += 1
            }
        }
        guard index < arguments.count else { return nil }
        let container = arguments[index]
        var inner = Array(arguments.dropFirst(index + 1))
        if inner.first == "--" {
            inner.removeFirst()
        }
        return (interactive, container, inner)
    }

    private static func wrapperInner(command: String, arguments: [String]) -> [String]? {
        var rest = arguments
        switch command {
        case "timeout":
            while let first = rest.first, first.hasPrefix("-") {
                let optionName = first
                    .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init) ?? first
                let takesValue = ["-s", "-k", "--signal", "--kill-after"].contains(optionName)
                rest.removeFirst()
                if takesValue, !first.contains("="), !rest.isEmpty {
                    rest.removeFirst()
                }
            }
            guard !rest.isEmpty else { return nil }
            rest.removeFirst()
            return rest
        case "nice":
            while let first = rest.first, first.hasPrefix("-") {
                rest.removeFirst()
                if first == "-n", !rest.isEmpty {
                    rest.removeFirst()
                }
            }
            return rest
        case "command":
            if rest.first == "-v" || rest.first == "-V" {
                return nil
            }
            while let first = rest.first, first.hasPrefix("-") {
                rest.removeFirst()
            }
            return rest
        case "nohup", "exec", "time", "builtin", "busybox":
            while let first = rest.first, first.hasPrefix("-") {
                rest.removeFirst()
            }
            return rest
        default:
            return nil
        }
    }

    private static func hasUnquotedCommandSubstitution(_ text: String) -> Bool {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if let activeQuote = quote {
                if activeQuote == "\"" {
                    if character == "`" {
                        return true
                    }
                    if (character == "$" || character == "<"),
                       next < text.endIndex, text[next] == "(" {
                        return true
                    }
                }
                if character == activeQuote,
                   !(index > text.startIndex && text[text.index(before: index)] == "\\") {
                    quote = nil
                }
                index = next
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = next
                continue
            }
            if character == "`" {
                return true
            }
            if (character == "$" || character == "<"),
               next < text.endIndex, text[next] == "(" {
                return true
            }
            index = next
        }
        return false
    }

    private static func hasUnquotedRedirection(_ text: String) -> Bool {
        var quote: Character?
        var previous: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if character == activeQuote,
                   !(index > text.startIndex && text[text.index(before: index)] == "\\") {
                    quote = nil
                }
                previous = character
                index = text.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                previous = character
                index = text.index(after: index)
                continue
            }
            if character == ">" {
                let next = text.index(after: index)
                if previous == "&" {
                    return true
                }
                if next < text.endIndex, text[next] == "&" {
                    previous = character
                    index = next
                    continue
                }
                return true
            }
            previous = character
            index = text.index(after: index)
        }
        return false
    }

    private static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if character == activeQuote,
                   !(index > text.startIndex && text[text.index(before: index)] == "\\") {
                    quote = nil
                } else {
                    current.append(character)
                }
                index = text.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = text.index(after: index)
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
            index = text.index(after: index)
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
