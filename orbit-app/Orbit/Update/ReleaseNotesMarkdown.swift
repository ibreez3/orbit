import Foundation

enum ReleaseNotesBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(Int, String)
    case code(String)
    case quote(String)
    case divider
}

enum ReleaseNotesMarkdownParser {
    static func parse(_ markdown: String) -> [ReleaseNotesBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [ReleaseNotesBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }
            if let heading = headingBlock(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            if let bullet = bulletBlock(trimmed) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                continue
            }
            if let numbered = numberedBlock(trimmed) {
                flushParagraph()
                blocks.append(.numbered(numbered.0, numbered.1))
                continue
            }
            paragraph.append(trimmed)
        }

        if inCode {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func headingBlock(_ line: String) -> ReleaseNotesBlock? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, text: String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private static func bulletBlock(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if line.hasPrefix(prefix) { return String(line.dropFirst(2)) }
        }
        return nil
    }

    private static func numberedBlock(_ line: String) -> (Int, String)? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let prefix = String(line[..<space])
        guard prefix.hasSuffix("."), let number = Int(prefix.dropLast()) else { return nil }
        let text = String(line[line.index(after: space)...])
        return (number, text)
    }
}
