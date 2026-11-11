import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 1024, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            OrbitCommands()
        }
    }
}

struct OrbitCommands: Commands {
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var keyBindings = KeyBindings.shared

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .appInfo) {
            Button("关于 Orbit") {
                AboutWindowController.shared.open()
            }
        }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                updateManager.checkForUpdates()
            }
            .disabled(!updateManager.canCheckForUpdates || updateManager.status == .checking)
        }
        CommandGroup(after: .toolbar) {
            Button("快速终端") {
                QuickTerminalController.shared.toggle()
            }
            .keyboardShortcut("`", modifiers: .control)

            Button("快速连接") {
                NotificationCenter.default.post(name: .focusQuickConnect, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "quickConnect"),
                modifiers: eventModifiers(for: "quickConnect")
            )

            Button("命令面板") {
                NotificationCenter.default.post(name: .openCommandPalette, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "commandPalette"),
                modifiers: eventModifiers(for: "commandPalette")
            )

            Button("Toggle SFTP Drawer") {
                NotificationCenter.default.post(name: .toggleSftpDrawer, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "toggleSftp"),
                modifiers: eventModifiers(for: "toggleSftp")
            )

            Button("Clear Screen") {
                NotificationCenter.default.post(name: .clearScreen, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "clearScreen"),
                modifiers: eventModifiers(for: "clearScreen")
            )

            Button("Find in Terminal") {
                NotificationCenter.default.post(name: .findInTerminal, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "findInTerminal"),
                modifiers: eventModifiers(for: "findInTerminal")
            )

            Button("Open Settings") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "settings"),
                modifiers: eventModifiers(for: "settings")
            )

            Button("Reconnect Session") {
                NotificationCenter.default.post(name: .reconnectSession, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "reconnect"),
                modifiers: eventModifiers(for: "reconnect")
            )

            Divider()

            Button("Open Command Snippets") {
                NotificationCenter.default.post(name: .openSnippetPicker, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Toggle AI Assistant") {
                NotificationCenter.default.post(name: .toggleAIPanel, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) {
            Button("新建终端连接") {
                NotificationCenter.default.post(name: .newTerminal, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "newTerminal"),
                modifiers: eventModifiers(for: "newTerminal")
            )
        }
        CommandMenu("分屏") {
            Button("水平分屏（左右）") {
                NotificationCenter.default.post(name: .splitHorizontal, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "splitHorizontal"),
                modifiers: eventModifiers(for: "splitHorizontal")
            )

            Button("垂直分屏（上下）") {
                NotificationCenter.default.post(name: .splitVertical, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "splitVertical"),
                modifiers: eventModifiers(for: "splitVertical")
            )

            Divider()

            Button("关闭当前窗格") {
                NotificationCenter.default.post(name: .closePane, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "closePane"),
                modifiers: eventModifiers(for: "closePane")
            )

            Divider()

            Button("切换到上一个窗格") {
                NotificationCenter.default.post(name: .navigatePrevPane, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "navPrevPane"),
                modifiers: eventModifiers(for: "navPrevPane")
            )

            Button("切换到下一个窗格") {
                NotificationCenter.default.post(name: .navigateNextPane, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "navNextPane"),
                modifiers: eventModifiers(for: "navNextPane")
            )

            Button("切换到左侧窗格") {
                NotificationCenter.default.post(name: .navigateLeftPane, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "navLeftPane"),
                modifiers: eventModifiers(for: "navLeftPane")
            )

            Button("切换到右侧窗格") {
                NotificationCenter.default.post(name: .navigateRightPane, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "navRightPane"),
                modifiers: eventModifiers(for: "navRightPane")
            )

            Divider()

            Button("增大当前窗格") {
                NotificationCenter.default.post(name: .growPane, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "growPane"),
                modifiers: eventModifiers(for: "growPane")
            )

            Button("缩小当前窗格") {
                NotificationCenter.default.post(name: .shrinkPane, object: nil)
            }
            .keyboardShortcut(
                keyEquivalent(for: "shrinkPane"),
                modifiers: eventModifiers(for: "shrinkPane")
            )
        }
    }

    private func keyEquivalent(for action: String) -> KeyEquivalent {
        switch keyBindings.binding(for: action).key {
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "delete": return .delete
        case "return": return .return
        case "tab": return .tab
        case "escape": return .escape
        case "space": return .space
        default:
            return KeyEquivalent(keyBindings.binding(for: action).key.first ?? " ")
        }
    }

    private func eventModifiers(for action: String) -> EventModifiers {
        let modifiers = keyBindings.binding(for: action).modifiers
        var result = EventModifiers()
        if modifiers.command { result.insert(.command) }
        if modifiers.shift { result.insert(.shift) }
        if modifiers.option { result.insert(.option) }
        if modifiers.control { result.insert(.control) }
        return result
    }
}

extension Notification.Name {
    static let newTerminal = Notification.Name("newTerminal")
    static let focusQuickConnect = Notification.Name("focusQuickConnect")
    static let openCommandPalette = Notification.Name("openCommandPalette")
    static let splitHorizontal = Notification.Name("splitHorizontal")
    static let splitVertical = Notification.Name("splitVertical")
    static let closePane = Notification.Name("closePane")
    static let navigatePrevPane = Notification.Name("navigatePrevPane")
    static let navigateNextPane = Notification.Name("navigateNextPane")
    static let navigateLeftPane = Notification.Name("navigateLeftPane")
    static let navigateRightPane = Notification.Name("navigateRightPane")
    static let growPane = Notification.Name("growPane")
    static let shrinkPane = Notification.Name("shrinkPane")
    static let toggleSftpDrawer = Notification.Name("toggleSftpDrawer")
    static let clearScreen = Notification.Name("clearScreen")
    static let findInTerminal = Notification.Name("findInTerminal")
    static let openSettings = Notification.Name("openSettings")
    static let reconnectSession = Notification.Name("reconnectSession")
    static let openSnippetPicker = Notification.Name("openSnippetPicker")
    static let toggleAIPanel = Notification.Name("toggleAIPanel")
    static let openBatchExecution = Notification.Name("openBatchExecution")
    static let askAI = Notification.Name("askAI")
}
