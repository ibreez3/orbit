import Foundation
import AppKit

// MARK: - Config File Parser

/// Parses Ghostty-style INI key=value config files.
/// Format:
///   # comment
///   key = value
///   [section]
///   key = value
struct ConfigFile {
    var entries: [String: [String: String]] = [:]

    init() {}

    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self = ConfigFile.parse(text)
    }

    init(text: String) {
        self = ConfigFile.parse(text)
    }

    private static func parse(_ text: String) -> ConfigFile {
        var config = ConfigFile()
        var currentSection = ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Section header
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                continue
            }

            // Key = Value
            if let sepRange = trimmed.range(of: "=", options: .literal) {
                let key = String(trimmed[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if config.entries[currentSection] == nil {
                    config.entries[currentSection] = [:]
                }
                config.entries[currentSection]?[key] = value
            }
        }
        return config
    }

    func get(_ key: String, section: String = "") -> String? {
        return entries[section]?[key]
    }

    func get(_ key: String, section: String = "", default defaultValue: String) -> String {
        return entries[section]?[key] ?? defaultValue
    }
}

// MARK: - Orbit Theme File

/// Represents a loaded theme from a config file.
/// Theme files use sections: [palette], [window], [cursor]
struct OrbitTheme: Identifiable {
    let id: String          // filename without extension
    let name: String        // display name
    let url: URL?           // source file URL (nil for built-in)
    let colors: ThemeColors

    static let fileExtension = "orbit-theme"

    init(id: String, name: String, url: URL? = nil, colors: ThemeColors) {
        self.id = id
        self.name = name
        self.url = url
        self.colors = colors
    }

    init?(from url: URL) {
        guard let config = try? ConfigFile(contentsOf: url) else { return nil }
        self.url = url
        self.id = url.deletingPathExtension().lastPathComponent

        let name = config.get("name") ?? id
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        // Capitalize first letter of each word
        self.name = name.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")

        self.colors = Self.parseColors(from: config, fallbackId: id)
    }

    private static func parseColors(from config: ConfigFile, fallbackId: String) -> ThemeColors {
        // Parse background
        let bg = parseColor(config.get("background", section: "palette"), default: (0.11, 0.11, 0.12))
        let fg = parseColor(config.get("foreground", section: "palette"), default: (0.96, 0.96, 0.97))
        let winBg = parseColor(config.get("background", section: "window"), default: bg)
        let cursor = parseColor(config.get("color", section: "cursor"), default: fg)

        // Parse 16 ANSI colors
        let colorKeys = [
            "ansi-0", "ansi-1", "ansi-2", "ansi-3", "ansi-4", "ansi-5", "ansi-6", "ansi-7",
            "ansi-8", "ansi-9", "ansi-10", "ansi-11", "ansi-12", "ansi-13", "ansi-14", "ansi-15"
        ]
        let defaultAnsi: [(red: UInt16, green: UInt16, blue: UInt16)] = [
            (0x1C1C, 0x1C1E, 0x1EFF), (0xFF45, 0x453A, 0x3AFF),
            (0x30D1, 0xD158, 0x58FF), (0xFF9F, 0x9F0A, 0x0AFF),
            (0x0A84, 0x84FF, 0xFFFF), (0xBF5A, 0x5AF2, 0xF2FF),
            (0x64D2, 0xD2FF, 0xFFFF), (0x9898, 0x989D, 0x9DFF),
            (0x3939, 0x393B, 0x3BFF), (0xFF45, 0x453A, 0x3AFF),
            (0x30D1, 0xD158, 0x58FF), (0xFF9F, 0x9F0A, 0x0AFF),
            (0x0A84, 0x84FF, 0xFFFF), (0xBF5A, 0x5AF2, 0xF2FF),
            (0x64D2, 0xD2FF, 0xFFFF), (0xF5F5, 0xF5F7, 0xF7FF),
        ]

        var ansi = defaultAnsi
        for (i, key) in colorKeys.enumerated() {
            if let hex = config.get(key, section: "palette") {
                ansi[i] = parseHexColor16(hex)
            }
        }

        return ThemeColors(
            background: bg,
            foreground: fg,
            windowBg: winBg,
            cursor: cursor,
            ansi: ansi
        )
    }

    /// Parse "r, g, b" (0.0-1.0 floats) or "#rrggbb" hex
    private static func parseColor(_ string: String?, default fallback: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
        guard let s = string else { return fallback }
        let trimmed = s.trimmingCharacters(in: .whitespaces)

        // Hex format: #rrggbb
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            if let rgb = hexToFloat(hex) {
                return rgb
            }
            return fallback
        }

        // Float format: 0.5, 0.5, 0.5
        let parts = trimmed.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 3 {
            return (CGFloat(parts[0]), CGFloat(parts[1]), CGFloat(parts[2]))
        }

        return fallback
    }

    private static func hexToFloat(_ hex: String) -> (CGFloat, CGFloat, CGFloat)? {
        var val: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&val)
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return (r, g, b)
    }

    private static func parseHexColor16(_ hex: String) -> (red: UInt16, green: UInt16, blue: UInt16) {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        let clean = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        var val: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&val)
        let r8 = UInt16((val >> 16) & 0xFF)
        let g8 = UInt16((val >> 8) & 0xFF)
        let b8 = UInt16(val & 0xFF)
        return ((r8 << 8) | r8, (g8 << 8) | g8, (b8 << 8) | b8)
    }
}

// MARK: - Theme Manager

class ThemeManager {
    static let shared = ThemeManager()

    private(set) var themes: [OrbitTheme] = []
    private let themesDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        themesDir = appSupport.appendingPathComponent("Orbit/themes", isDirectory: true)
    }

    func loadThemes() {
        var loaded: [OrbitTheme] = []

        // 1. Built-in themes from bundle
        if let bundleThemes = Bundle.main.urls(forResourcesWithExtension: OrbitTheme.fileExtension, subdirectory: "Themes") {
            for url in bundleThemes {
                if let theme = OrbitTheme(from: url) {
                    loaded.append(theme)
                }
            }
        }

        // 2. User themes from Application Support
        try? FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        if let userThemes = try? FileManager.default.contentsOfDirectory(at: themesDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == OrbitTheme.fileExtension }) {
            for url in userThemes {
                if let theme = OrbitTheme(from: url) {
                    // User theme overrides built-in with same id
                    loaded.removeAll { $0.id == theme.id }
                    loaded.append(theme)
                }
            }
        }

        // Sort alphabetically
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.themes = loaded
    }

    func theme(withId id: String) -> OrbitTheme? {
        return themes.first { $0.id == id }
    }

    /// Returns the full path to the user themes directory for display/creation
    var userThemesPath: String { themesDir.path }
}

// MARK: - Built-in theme generators

extension OrbitTheme {
    static let builtInLight = OrbitTheme(
        id: "light",
        name: "Light",
        colors: ThemeColors(
            background: (1.0, 1.0, 1.0),
            foreground: (0.114, 0.114, 0.122),
            windowBg: (0.96, 0.96, 0.97),
            cursor: (0.114, 0.114, 0.122),
            ansi: [
                (0x0000, 0x0000, 0x0000), (0xFF3B, 0x3B30, 0x30FF),
                (0x34C7, 0xC759, 0x59FF), (0xFF95, 0x9500, 0x00FF),
                (0x007A, 0x7AFF, 0xFF00), (0xAF52, 0x52DE, 0xDEFF),
                (0x5AC8, 0xC8FA, 0xFAFF), (0x8E8E, 0x8E93, 0x93FF),
                (0x6363, 0x6366, 0x66FF), (0xFF45, 0x453A, 0x3AFF),
                (0x30D1, 0xD158, 0x58FF), (0xFF9F, 0x9F0A, 0x0AFF),
                (0x0A84, 0x84FF, 0xFFFF), (0xBF5A, 0x5AF2, 0xF2FF),
                (0x64D2, 0xD2FF, 0xFFFF), (0x1D1D, 0x1D1F, 0x1FFF),
            ]
        )
    )

    static let builtInDark = OrbitTheme(
        id: "dark",
        name: "Dark",
        colors: ThemeColors(
            background: (0.110, 0.110, 0.118),
            foreground: (0.961, 0.961, 0.965),
            windowBg: (0.0, 0.0, 0.0),
            cursor: (0.961, 0.961, 0.965),
            ansi: [
                (0x1C1C, 0x1C1E, 0x1EFF), (0xFF45, 0x453A, 0x3AFF),
                (0x30D1, 0xD158, 0x58FF), (0xFF9F, 0x9F0A, 0x0AFF),
                (0x0A84, 0x84FF, 0xFFFF), (0xBF5A, 0x5AF2, 0xF2FF),
                (0x64D2, 0xD2FF, 0xFFFF), (0x9898, 0x989D, 0x9DFF),
                (0x3939, 0x393B, 0x3BFF), (0xFF45, 0x453A, 0x3AFF),
                (0x30D1, 0xD158, 0x58FF), (0xFF9F, 0x9F0A, 0x0AFF),
                (0x0A84, 0x84FF, 0xFFFF), (0xBF5A, 0x5AF2, 0xF2FF),
                (0x64D2, 0xD2FF, 0xFFFF), (0xF5F5, 0xF5F7, 0xF7FF),
            ]
        )
    )

    static let builtInCatppuccinMocha = OrbitTheme(
        id: "catppuccinMocha",
        name: "Catppuccin Mocha",
        colors: ThemeColors(
            background: (0.118, 0.118, 0.180),
            foreground: (0.804, 0.827, 0.957),
            windowBg: (0.067, 0.067, 0.106),
            cursor: (0.804, 0.827, 0.957),
            ansi: [
                (0x4545, 0x4747, 0x5A5A), (0xF3F3, 0x8B8B, 0xA8A8),
                (0xA6A6, 0xE3E3, 0xA1A1), (0xF9F9, 0xE2E2, 0xAFAF),
                (0x8989, 0xB4B4, 0xFAFA), (0xF5F5, 0xC2C2, 0xE7E7),
                (0x9494, 0xE2E2, 0xD5D5), (0xBABA, 0xC2C2, 0xDEDE),
                (0x5858, 0x5B5B, 0x7070), (0xF3F3, 0x8B8B, 0xA8A8),
                (0xA6A6, 0xE3E3, 0xA1A1), (0xF9F9, 0xE2E2, 0xAFAF),
                (0x8989, 0xB4B4, 0xFAFA), (0xF5F5, 0xC2C2, 0xE7E7),
                (0x9494, 0xE2E2, 0xD5D5), (0xA6A6, 0xADAD, 0xC8C8),
            ]
        )
    )

    static let builtInDracula = OrbitTheme(
        id: "dracula",
        name: "Dracula",
        colors: ThemeColors(
            background: (0.157, 0.165, 0.212),
            foreground: (0.973, 0.973, 0.949),
            windowBg: (0.043, 0.051, 0.075),
            cursor: (0.973, 0.973, 0.949),
            ansi: [
                (0x2121, 0x2222, 0x2C2C), (0xFFFF, 0x5555, 0x5555),
                (0x5050, 0xFAFA, 0x7B7B), (0xF1F1, 0xFAFA, 0x8C8C),
                (0xBDBD, 0x9393, 0xF9F9), (0xFFFF, 0x7979, 0xC6C6),
                (0x8B8B, 0xE9E9, 0xFDFD), (0xF8F8, 0xF8F8, 0xF2F2),
                (0x6262, 0x7272, 0xA4A4), (0xFFFF, 0x6E6E, 0x6E6E),
                (0x6969, 0xFFFF, 0x9494), (0xFFFF, 0xFFFF, 0xA5A5),
                (0xD6D6, 0xACAC, 0xFFFF), (0xFFFF, 0x9292, 0xDFDF),
                (0xA4A4, 0xFFFF, 0xFFFF), (0xFFFF, 0xFFFF, 0xFFFF),
            ]
        )
    )

    static let builtInTokyoNight = OrbitTheme(
        id: "tokyoNight",
        name: "Tokyo Night",
        colors: ThemeColors(
            background: (0.102, 0.106, 0.149),
            foreground: (0.663, 0.694, 0.839),
            windowBg: (0.059, 0.059, 0.078),
            cursor: (0.663, 0.694, 0.839),
            ansi: [
                (0x1515, 0x1616, 0x1E1E), (0xF7F7, 0x7676, 0x8E8E),
                (0x9E9E, 0xCECE, 0x6A6A), (0xE0E0, 0xAFAF, 0x6868),
                (0x7A7A, 0xA2A2, 0xF7F7), (0xBBBB, 0x9A9A, 0xF7F7),
                (0x7D7D, 0xCFCF, 0xFFFF), (0xA9A9, 0xB1B1, 0xD6D6),
                (0x4141, 0x4848, 0x6868), (0xF7F7, 0x7676, 0x8E8E),
                (0x9E9E, 0xCECE, 0x6A6A), (0xE0E0, 0xAFAF, 0x6868),
                (0x7A7A, 0xA2A2, 0xF7F7), (0xBBBB, 0x9A9A, 0xF7F7),
                (0x7D7D, 0xCFCF, 0xFFFF), (0xC0C0, 0xCACA, 0xF5F5),
            ]
        )
    )

    static let builtInNord = OrbitTheme(
        id: "nord",
        name: "Nord",
        colors: ThemeColors(
            background: (0.180, 0.204, 0.251),
            foreground: (0.847, 0.871, 0.914),
            windowBg: (0.098, 0.118, 0.157),
            cursor: (0.847, 0.871, 0.914),
            ansi: [
                (0x3B3B, 0x4242, 0x5252), (0xBFBF, 0x6161, 0x6A6A),
                (0xA3A3, 0xBEBE, 0x8C8C), (0xEBEB, 0xCBCB, 0x8B8B),
                (0x8181, 0xA1A1, 0xC1C1), (0xB4B4, 0x8E8E, 0xADAD),
                (0x8F8F, 0xBCBC, 0xBBBB), (0xD8D8, 0xDEDE, 0xE9E9),
                (0x4C4C, 0x5656, 0x6A6A), (0xBFBF, 0x6161, 0x6A6A),
                (0xA3A3, 0xBEBE, 0x8C8C), (0xEBEB, 0xCBCB, 0x8B8B),
                (0x8181, 0xA1A1, 0xC1C1), (0xB4B4, 0x8E8E, 0xADAD),
                (0x8F8F, 0xBCBC, 0xBBBB), (0xECEC, 0xEFEF, 0xF4F4),
            ]
        )
    )

    static let builtInSolarizedDark = OrbitTheme(
        id: "solarizedDark",
        name: "Solarized Dark",
        colors: ThemeColors(
            background: (0.000, 0.169, 0.212),
            foreground: (0.514, 0.580, 0.588),
            windowBg: (0.000, 0.118, 0.149),
            cursor: (0.514, 0.580, 0.588),
            ansi: [
                (0x0707, 0x3636, 0x4242), (0xDCDC, 0x3232, 0x2F2F),
                (0x8585, 0x9999, 0x0000), (0xB5B5, 0x8989, 0x0000),
                (0x2626, 0x8B8B, 0xD2D2), (0x6C6C, 0x7171, 0xC4C4),
                (0x2A2A, 0xA1A1, 0x9898), (0xEEEE, 0xE8E8, 0xD5D5),
                (0x0000, 0x2B2B, 0x3636), (0xCBCB, 0x4B4B, 0x1616),
                (0x5858, 0x6E6E, 0x7575), (0x6565, 0x7B7B, 0x8383),
                (0x8383, 0x9494, 0x9696), (0x6C6C, 0x7171, 0xC4C4),
                (0x9393, 0xA1A1, 0xA1A1), (0xFDFD, 0xF6F6, 0xE3E3),
            ]
        )
    )

    static let builtInGruvboxDark = OrbitTheme(
        id: "gruvboxDark",
        name: "Gruvbox Dark",
        colors: ThemeColors(
            background: (0.157, 0.157, 0.157),
            foreground: (0.835, 0.769, 0.631),
            windowBg: (0.114, 0.125, 0.129),
            cursor: (0.835, 0.769, 0.631),
            ansi: [
                (0x1D1D, 0x2020, 0x2121), (0xCCCC, 0x2424, 0x1D1D),
                (0x9898, 0x9797, 0x1A1A), (0xD7D7, 0x9999, 0x2121),
                (0x4545, 0x8585, 0x8888), (0xB1B1, 0x6262, 0xD8D8),
                (0x6868, 0x9D9D, 0x6A6A), (0xA8A8, 0x9999, 0x8484),
                (0x5050, 0x4949, 0x4545), (0xFBFB, 0x4949, 0x3434),
                (0xB8B8, 0xBBBB, 0x2626), (0xFAFA, 0xBDBD, 0x2F2F),
                (0x8383, 0xA5A5, 0x9898), (0xD3D3, 0x8686, 0x9B9B),
                (0x8E8E, 0xC0C0, 0x7C7C), (0xEBEB, 0xDBDB, 0xB2B2),
            ]
        )
    )

    static let allBuiltIn: [OrbitTheme] = [
        .builtInLight, .builtInDark, .builtInCatppuccinMocha,
        .builtInDracula, .builtInTokyoNight, .builtInNord,
        .builtInSolarizedDark, .builtInGruvboxDark,
    ]
}
