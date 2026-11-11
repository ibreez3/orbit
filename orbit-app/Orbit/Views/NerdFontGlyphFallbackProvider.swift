import AppKit
import CoreText
import SwiftTerm

/// Supplies Nerd Font glyphs only for private-use icon codepoints that the
/// selected terminal font cannot draw. The text font stays untouched, and
/// ordinary missing letters are left to CoreText's normal fallback.
final class NerdFontGlyphFallbackProvider: TerminalGlyphFallbackProvider, @unchecked Sendable {
    static let shared = NerdFontGlyphFallbackProvider()

    private let lock = NSLock()
    private let fallbackPostScriptName: String?
    private var fonts: [CGFloat: CTFont] = [:]
    private var coverage: [UInt32: Bool] = [:]

    let generation: UInt64 = 1

    var isAvailable: Bool { fallbackPostScriptName != nil }

    private init() {
        fallbackPostScriptName = Self.resolveFallbackPostScriptName()
    }

    func placementPolicy(for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        guard Self.isPrivateUse(scalar), fallbackCovers(scalar) else { return nil }
        // Powerline separators are designed to fill the cell; normal Nerd
        // Font icons should keep their aspect ratio and be centered.
        if (0xE0A0...0xE0C8).contains(scalar.value) {
            return TerminalGlyphPlacementPolicy(placement: .stretch)
        }
        return TerminalGlyphPlacementPolicy(placement: .icon)
    }

    func fallbackFont(forPointSize size: CGFloat) -> CTFont? {
        lock.lock()
        defer { lock.unlock() }
        return fallbackFontLocked(forPointSize: size)
    }

    private func fallbackFontLocked(forPointSize size: CGFloat) -> CTFont? {
        if let cached = fonts[size] { return cached }
        guard let name = fallbackPostScriptName else { return nil }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        fonts[size] = font
        return font
    }

    private func fallbackCovers(_ scalar: Unicode.Scalar) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached = coverage[scalar.value] { return cached }
        guard let font = fallbackFontLocked(forPointSize: 14) else {
            coverage[scalar.value] = false
            return false
        }
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        let mapped = units.withUnsafeBufferPointer { unitsPointer in
            glyphs.withUnsafeMutableBufferPointer { glyphsPointer in
                CTFontGetGlyphsForCharacters(
                    font,
                    unitsPointer.baseAddress!,
                    glyphsPointer.baseAddress!,
                    units.count
                )
            }
        }
        let covered = mapped && glyphs.first != 0
        coverage[scalar.value] = covered
        return covered
    }

    private static func resolveFallbackPostScriptName() -> String? {
        let candidates = ["Symbols Nerd Font Mono"]
            + TerminalRenderSettings.preferredFontNames.filter {
                $0.contains("Nerd Font Mono") || $0.hasSuffix(" NF")
            }
        for name in candidates {
            if let font = NSFont(name: name, size: 14) {
                return font.fontName
            }
        }
        return nil
    }

    private static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD:
            return true
        default:
            return false
        }
    }
}
