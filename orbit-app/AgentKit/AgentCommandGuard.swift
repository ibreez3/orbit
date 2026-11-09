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
        "tee", "eval", "xargs", "env", "sudo"
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
            if rest.contains(where: { $0.hasPrefix("-") && $0.contains("t") }) {
                return "Interactive docker exec requires write approval"
            }
            guard let containerIndex = rest.firstIndex(where: { !$0.hasPrefix("-") }) else {
                return "docker exec requires a container and command"
            }
            let inner = Array(rest.dropFirst(containerIndex + 1))
            guard !inner.isEmpty else {
                return "docker exec requires an inner command"
            }
            return inspect(inner.joined(separator: " "))
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
                if next < command.endIndex, command[next] == "&" {
                    segments.append(current)
                    current = ""
                    index = command.index(after: next)
                    continue
                }
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
