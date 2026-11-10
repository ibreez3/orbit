import Foundation
import AppKit
import Combine

struct KeyBinding: Codable, Hashable {
    let key: String       // e.g. "k", "f", "d", "\u{7f}" for delete
    let modifiers: Modifiers

    struct Modifiers: Codable, Hashable {
        let command: Bool
        let shift: Bool
        let option: Bool
        let control: Bool

        var isEmpty: Bool { !command && !shift && !option && !control }

        var displayString: String {
            var parts: [String] = []
            if control { parts.append("⌃") }
            if option  { parts.append("⌥") }
            if shift   { parts.append("⇧") }
            if command { parts.append("⌘") }
            return parts.joined()
        }

        init(command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
        }

        init(flags: NSEvent.ModifierFlags) {
            self.command = flags.contains(.command)
            self.shift   = flags.contains(.shift)
            self.option  = flags.contains(.option)
            self.control = flags.contains(.control)
        }

        var nseventMask: NSEvent.ModifierFlags {
            var mask = NSEvent.ModifierFlags()
            if command { mask.insert(.command) }
            if shift   { mask.insert(.shift) }
            if option  { mask.insert(.option) }
            if control { mask.insert(.control) }
            return mask
        }
    }

    var displayString: String {
        "\(modifiers.displayString)\(Self.displayKey(key))"
    }

    static func displayKey(_ key: String) -> String {
        switch key {
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        case "delete": return "⌫"
        case "return": return "↩"
        case "tab": return "⇥"
        case "escape": return "⎋"
        case "space": return "␣"
        default: return key.uppercased()
        }
    }

    /// Converts an AppKit key event into a stable binding token. Named tokens
    /// are used for keys whose characters are control codes (arrows, escape…)
    /// so the settings UI can display and persist them unambiguously.
    static func token(keyCode: UInt16, characters: String?) -> String? {
        switch keyCode {
        case 126: return "up"
        case 125: return "down"
        case 123: return "left"
        case 124: return "right"
        case 0x33: return "delete"
        case 0x24: return "return"
        case 0x30: return "tab"
        case 0x35: return "escape"
        case 0x31: return "space"
        default:
            guard let characters, !characters.isEmpty else { return nil }
            return characters.lowercased()
        }
    }

    init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.modifiers = Modifiers(command: command, shift: shift, option: option, control: control)
    }
}

enum WorkspaceEntryPoint: Equatable {
    case quickConnect
    case commandPalette
}

struct WorkspaceKeyboardInput: Equatable {
    let key: String
    let modifiers: KeyBinding.Modifiers
    let isRepeat: Bool
    let isWorkspaceWindow: Bool

    init(
        key: String,
        modifiers: KeyBinding.Modifiers,
        isRepeat: Bool = false,
        isWorkspaceWindow: Bool = true
    ) {
        self.key = key.lowercased()
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.isWorkspaceWindow = isWorkspaceWindow
    }
}

enum WorkspaceKeyboardRoute: Equatable {
    case passThrough
    case consume
    case dispatch(WorkspaceEntryPoint)
}

struct WorkspaceKeyboardRouter {
    let bindings: KeyBindings

    func route(for input: WorkspaceKeyboardInput) -> WorkspaceKeyboardRoute {
        guard input.isWorkspaceWindow, !input.modifiers.isEmpty else {
            return .passThrough
        }

        let quickConnectMatches = matches(input, action: "quickConnect")
        let commandPaletteMatches = matches(input, action: "commandPalette")
        guard quickConnectMatches || commandPaletteMatches else {
            return .passThrough
        }
        guard !input.isRepeat, quickConnectMatches != commandPaletteMatches else {
            return .consume
        }
        return .dispatch(quickConnectMatches ? .quickConnect : .commandPalette)
    }

    private func matches(_ input: WorkspaceKeyboardInput, action: String) -> Bool {
        let binding = bindings.binding(for: action)
        return binding.key.lowercased() == input.key && binding.modifiers == input.modifiers
    }
}

protocol KeyBindingStore: AnyObject {
    func load() -> [String: KeyBinding]?
    func save(_ bindings: [String: KeyBinding])
    func clear()
}

final class UserDefaultsKeyBindingStore: KeyBindingStore {
    private let defaults: UserDefaults
    private let key: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard, key: String = "keyBindings_json") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [String: KeyBinding]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode([String: KeyBinding].self, from: data)
    }

    func save(_ bindings: [String: KeyBinding]) {
        guard let data = try? encoder.encode(bindings) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

final class KeyBindings: ObservableObject {
    static let shared = KeyBindings()

    @Published private(set) var revision = 0
    private var bindings: [String: KeyBinding] = [:]
    private let store: KeyBindingStore

    init(store: KeyBindingStore = UserDefaultsKeyBindingStore()) {
        self.store = store
        loadDefaults()
    }

    // MARK: - Public API

    func binding(for action: String) -> KeyBinding {
        bindings[action] ?? Self.defaultBindings[action]!
    }

    func setBinding(action: String, key: String, modifiers: KeyBinding.Modifiers) {
        bindings[action] = KeyBinding(key: key, command: modifiers.command, shift: modifiers.shift, option: modifiers.option, control: modifiers.control)
        persist()
        revision &+= 1
    }

    func resetToDefaults() {
        bindings = [:]
        store.clear()
        revision &+= 1
    }

    /// Check if an NSEvent matches a registered keybinding. Returns the action name if matched.
    func match(event: NSEvent) -> String? {
        let flags = KeyBinding.Modifiers(
            flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
        guard !flags.isEmpty,
              let key = KeyBinding.token(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers
              ) else {
            return nil
        }

        for (action, kb) in bindings where kb.key == key && kb.modifiers == flags {
            return action
        }
        for (action, kb) in Self.defaultBindings where kb.key == key && kb.modifiers == flags {
            if bindings[action] == nil { return action }
        }
        return nil
    }

    func allActions() -> [(action: String, binding: KeyBinding)] {
        var result: [(String, KeyBinding)] = []
        let allActions = Set(Self.actionNames).union(Self.defaultBindings.keys)
        for action in allActions.sorted() {
            result.append((action, binding(for: action)))
        }
        return result
    }

    // MARK: - Defaults

    static let actionNames: [String] = [
        "quickConnect", "commandPalette", "settings", "newTerminal", "toggleSftp", "findInTerminal",
        "clearScreen", "reconnect",
        "splitHorizontal", "splitVertical", "closePane",
        "navPrevPane", "navNextPane", "navLeftPane", "navRightPane",
        "growPane", "shrinkPane",
    ]

    static let defaultBindings: [String: KeyBinding] = [
        "quickConnect":   KeyBinding(key: "k", command: true),
        "commandPalette": KeyBinding(key: "p", command: true, shift: true),
        "settings":       KeyBinding(key: ",", command: true),
        "newTerminal":    KeyBinding(key: "t", command: true),
        "toggleSftp":     KeyBinding(key: "f", command: true, shift: true),
        "findInTerminal": KeyBinding(key: "f", command: true),
        "clearScreen":    KeyBinding(key: "l", command: true),
        "reconnect":      KeyBinding(key: "r", command: true, shift: true),
        "splitHorizontal":  KeyBinding(key: "d", command: true),
        "splitVertical":    KeyBinding(key: "d", command: true, shift: true),
        "closePane":      KeyBinding(key: "w", command: true),
        "navPrevPane":    KeyBinding(key: "up", command: true, option: true),
        "navNextPane":    KeyBinding(key: "down", command: true, option: true),
        "navLeftPane":    KeyBinding(key: "left", command: true, option: true),
        "navRightPane":   KeyBinding(key: "right", command: true, option: true),
        "growPane":       KeyBinding(key: "right", command: true, shift: true),
        "shrinkPane":     KeyBinding(key: "left", command: true, shift: true),
    ]

    // MARK: - Persistence

    private func loadDefaults() {
        var loaded = store.load() ?? [:]
        var migrated = false
        if loaded["commandPalette"] == nil,
           let legacyBinding = loaded.removeValue(forKey: "spotlight") {
            loaded["commandPalette"] = legacyBinding
            migrated = true
        }
        for (action, binding) in loaded {
            if let token = Self.legacyKeyToken(binding.key), token != binding.key {
                loaded[action] = KeyBinding(
                    key: token,
                    command: binding.modifiers.command,
                    shift: binding.modifiers.shift,
                    option: binding.modifiers.option,
                    control: binding.modifiers.control
                )
                migrated = true
            }
        }
        bindings = loaded
        if migrated {
            persist()
        }
    }

    private static func legacyKeyToken(_ key: String) -> String? {
        switch key {
        case "\u{1b}": return "up"
        case "\u{1c}": return "down"
        case "\u{1d}": return "left"
        case "\u{1e}": return "right"
        case "\u{7f}": return "delete"
        case "\r": return "return"
        case "\t": return "tab"
        case " ": return "space"
        default: return nil
        }
    }

    private func persist() {
        store.save(bindings)
    }
}
