import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            OrbitCommands()
        }
    }
}

struct OrbitCommands: Commands {
    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .toolbar) {
            Button("Spotlight") {
                NotificationCenter.default.post(name: .openSpotlight, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Toggle SFTP Drawer") {
                NotificationCenter.default.post(name: .toggleSftpDrawer, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Clear Screen") {
                NotificationCenter.default.post(name: .clearScreen, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Find in Terminal") {
                NotificationCenter.default.post(name: .findInTerminal, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Open Settings") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Reconnect Session") {
                NotificationCenter.default.post(name: .reconnectSession, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) {
            Button("新建终端连接") {
                NotificationCenter.default.post(name: .newTerminal, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)
        }
        CommandMenu("分屏") {
            Button("水平分屏（上下）") {
                NotificationCenter.default.post(name: .splitHorizontal, object: nil)
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("垂直分屏（左右）") {
                NotificationCenter.default.post(name: .splitVertical, object: nil)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("关闭当前窗格") {
                NotificationCenter.default.post(name: .closePane, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("切换到上一个窗格") {
                NotificationCenter.default.post(name: .navigatePrevPane, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button("切换到下一个窗格") {
                NotificationCenter.default.post(name: .navigateNextPane, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Button("切换到左侧窗格") {
                NotificationCenter.default.post(name: .navigateLeftPane, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button("切换到右侧窗格") {
                NotificationCenter.default.post(name: .navigateRightPane, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Divider()

            Button("增大当前窗格") {
                NotificationCenter.default.post(name: .growPane, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])

            Button("缩小当前窗格") {
                NotificationCenter.default.post(name: .shrinkPane, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let newTerminal = Notification.Name("newTerminal")
    static let openSpotlight = Notification.Name("openSpotlight")
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
}
