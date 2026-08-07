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
        let k = key.uppercased()
        return "\(modifiers.displayString)\(k)"
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
        let flags = KeyBinding.Modifiers(flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        guard !flags.isEmpty else { return nil }

        // Arrow keys: match by keyCode
        if let arrowAction = matchArrow(keyCode: event.keyCode, flags: flags) {
            return arrowAction
        }

        // Regular keys: match by character
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        for (action, kb) in bindings where kb.key == key && kb.modifiers == flags {
            return action
        }
        for (action, kb) in Self.defaultBindings where kb.key == key && kb.modifiers == flags {
            if bindings[action] == nil { return action }
        }
        return nil
    }

    private func matchArrow(keyCode: UInt16, flags: KeyBinding.Modifiers) -> String? {
        for (action, spec) in Self.arrowActions where spec.keyCode == keyCode && spec.modifiers == flags {
            // Check if user has overridden this arrow action
            if let kb = bindings[action], kb.modifiers == flags {
                // User explicitly bound something with same modifiers; let the character-based
                // path handle it. Arrow defaults still fire if the action isn't overridden.
                return action
            }
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
        "navPrevPane":    KeyBinding(key: "\u{1b}", command: true, option: true), // up arrow charcode
        "navNextPane":    KeyBinding(key: "\u{1c}", command: true, option: true),
        "navLeftPane":    KeyBinding(key: "\u{1d}", command: true, option: true),
        "navRightPane":   KeyBinding(key: "\u{1e}", command: true, option: true),
        "growPane":       KeyBinding(key: "\u{1e}", command: true, shift: true),
        "shrinkPane":     KeyBinding(key: "\u{1d}", command: true, shift: true),
    ]

    // Arrow key special handling – these return arrow charCodes from charactersIgnoringModifiers
    // The defaults above use charCodes; the actual match for arrow keys uses keyCode instead.
    static let arrowActions: [String: (keyCode: UInt16, modifiers: KeyBinding.Modifiers)] = [
        "navPrevPane":  (keyCode: 126, modifiers: KeyBinding.Modifiers(command: true, option: true)),  // Up
        "navNextPane":  (keyCode: 125, modifiers: KeyBinding.Modifiers(command: true, option: true)),  // Down
        "navLeftPane":  (keyCode: 123, modifiers: KeyBinding.Modifiers(command: true, option: true)),  // Left
        "navRightPane": (keyCode: 124, modifiers: KeyBinding.Modifiers(command: true, option: true)),  // Right
        "growPane":     (keyCode: 124, modifiers: KeyBinding.Modifiers(command: true, shift: true)),   // Right
        "shrinkPane":   (keyCode: 123, modifiers: KeyBinding.Modifiers(command: true, shift: true)),   // Left
    ]

    // MARK: - Persistence

    private func loadDefaults() {
        bindings = store.load() ?? [:]
        if bindings["commandPalette"] == nil,
           let legacyBinding = bindings.removeValue(forKey: "spotlight") {
            bindings["commandPalette"] = legacyBinding
            persist()
        }
    }

    private func persist() {
        store.save(bindings)
    }
}
