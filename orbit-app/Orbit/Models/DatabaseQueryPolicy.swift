import Foundation

/// Applies the "自动添加 LIMIT" preference to ad-hoc SQL.
enum DatabaseQueryPolicy {
    static func applyingAutoLimit(
        to sql: String,
        limit: Int,
        enabled: Bool
    ) -> String {
        guard enabled, limit > 0 else { return sql }

        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isPlainSelect(trimmed) else { return sql }

        let tokens = topLevelTokens(in: trimmed)
        guard !tokens.contains("limit"),
              !tokens.contains("into"),
              !containsSequence(["for", "update"], in: tokens),
              !containsSequence(["for", "share"], in: tokens) else {
            return sql
        }

        var base = trimmed
        while base.hasSuffix(";") {
            base.removeLast()
            base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !base.isEmpty else { return sql }
        return "\(base)\nLIMIT \(limit)"
    }

    static func isPlainSelect(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return false }
        let prefix = trimmed.prefix(6).lowercased()
        guard prefix == "select" else { return false }
        let next = trimmed.dropFirst(6).first
        return next == nil || next?.isWhitespace == true
    }

    /// Returns lowercased word tokens that sit outside string literals,
    /// quoted identifiers, comments, and nested parentheses.
    static func topLevelTokens(in sql: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        var index = sql.startIndex

        func flush() {
            if !current.isEmpty {
                tokens.append(current.lowercased())
                current.removeAll(keepingCapacity: true)
            }
        }

        while index < sql.endIndex {
            let character = sql[index]
            let nextIndex = sql.index(after: index)
            let next = nextIndex < sql.endIndex ? sql[nextIndex] : nil

            if character == "'" || character == "\"" || character == "`" {
                flush()
                let quote = character
                index = nextIndex
                while index < sql.endIndex {
                    let inner = sql[index]
                    if inner == quote {
                        let after = sql.index(after: index)
                        if after < sql.endIndex, sql[after] == quote {
                            index = sql.index(after: after)
                            continue
                        }
                        index = after
                        break
                    }
                    index = sql.index(after: index)
                }
                continue
            }

            if depth == 0, character == "-", next == "-" {
                flush()
                index = nextIndex
                while index < sql.endIndex, sql[index] != "\n" {
                    index = sql.index(after: index)
                }
                continue
            }

            if depth == 0, character == "/", next == "*" {
                flush()
                index = sql.index(after: nextIndex)
                while index < sql.endIndex {
                    if sql[index] == "*", sql.index(after: index) < sql.endIndex,
                       sql[sql.index(after: index)] == "/" {
                        index = sql.index(after: sql.index(after: index))
                        break
                    }
                    index = sql.index(after: index)
                }
                continue
            }

            if character == "(" {
                if depth == 0 { flush() }
                depth += 1
                index = nextIndex
                continue
            }
            if character == ")" {
                depth = max(0, depth - 1)
                index = nextIndex
                continue
            }

            if character.isLetter || character.isNumber || character == "_" {
                if depth == 0 {
                    current.append(character)
                }
            } else if depth == 0 {
                flush()
            }
            index = nextIndex
        }
        flush()
        return tokens
    }

    private static func containsSequence(_ sequence: [String], in tokens: [String]) -> Bool {
        guard sequence.count <= tokens.count else { return false }
        for start in 0...(tokens.count - sequence.count) {
            if Array(tokens[start..<(start + sequence.count)]) == sequence {
                return true
            }
        }
        return false
    }
}
