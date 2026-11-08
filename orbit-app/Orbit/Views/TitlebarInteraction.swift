import AppKit

/// The action macOS performs when the user double-clicks a window's title bar.
enum WindowDoubleClickAction: Equatable {
    case zoom
    case minimize
    case none

    static func resolve(preference: String?) -> WindowDoubleClickAction {
        switch preference {
        case "Minimize": return .minimize
        case "None": return .none
        default: return .zoom
        }
    }

    static var systemPreference: WindowDoubleClickAction {
        resolve(preference: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"))
    }
}

/// Restores native title-bar behavior for the SwiftUI workspace window.
///
/// SwiftUI hosts window content in a full-size content view, so clicks in the
/// title-bar strip never reach AppKit's title bar. This monitor gives that strip
/// its standard drag and double-click behavior without touching the
/// traffic-light buttons or any content below the strip.
final class TitlebarInteractionController {
    private var monitor: Any?
    private var windowNumberProvider: (() -> Int?)?

    func install(windowNumberProvider: @escaping () -> Int?) {
        uninstall()
        self.windowNumberProvider = windowNumberProvider
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = event.window else { return event }
            guard window.windowNumber == self.windowNumberProvider?() else { return event }
            return self.handle(event, in: window)
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        windowNumberProvider = nil
    }

    private func handle(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        let point = event.locationInWindow
        guard Self.isTitlebarPoint(point, in: window),
              !Self.isOverWindowButton(point, in: window) else {
            return event
        }

        switch event.clickCount {
        case 1:
            window.orbitPerformWindowDrag(with: event)
        case 2:
            Self.performDoubleClickAction(on: window)
        default:
            break
        }
        return nil
    }

    /// The title-bar strip sits above the window's content layout rectangle.
    /// `point` is in the window's base coordinate system.
    static func isTitlebarPoint(_ point: NSPoint, in window: NSWindow) -> Bool {
        let contentLayout = window.contentLayoutRect
        guard contentLayout.height > 0 else { return false }
        return point.y >= contentLayout.maxY - 0.5 && point.y <= window.frame.height
    }

    static func isOverWindowButton(_ point: NSPoint, in window: NSWindow) -> Bool {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttonTypes {
            guard let button = window.standardWindowButton(type), !button.isHidden else { continue }
            let frame = button.convert(button.bounds, to: nil).insetBy(dx: -2, dy: -2)
            if frame.contains(point) { return true }
        }
        return false
    }

    static func performDoubleClickAction(on window: NSWindow?) {
        guard let window else { return }
        switch WindowDoubleClickAction.systemPreference {
        case .zoom:
            window.performZoom(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .none:
            break
        }
    }
}

private extension NSWindow {
    /// The documented `performWindowDragWithEvent:` API is not imported into
    /// Swift by the macOS 26 SDK, so call it through its Objective-C selector.
    func orbitPerformWindowDrag(with event: NSEvent) {
        let selector = NSSelectorFromString("performWindowDragWithEvent:")
        guard responds(to: selector) else { return }
        perform(selector, with: event)
    }
}
