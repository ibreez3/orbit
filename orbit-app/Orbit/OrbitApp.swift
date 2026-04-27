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
        CommandGroup(replacing: .newItem) {
            Button("新建终端连接") {
                NotificationCenter.default.post(name: .newTerminal, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)
        }
    }
}

extension Notification.Name {
    static let newTerminal = Notification.Name("newTerminal")
}
