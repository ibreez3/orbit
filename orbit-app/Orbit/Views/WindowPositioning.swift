import AppKit

extension NSWindow {
    /// 将窗口居中到当前 app 的主窗口；没有可用主窗口时退回屏幕居中。
    func centerOverMainWindow() {
        guard let anchor = NSWindowPositioning.anchorWindow(excluding: self) else {
            center()
            return
        }
        let visibleFrame = (anchor.screen ?? screen ?? NSScreen.main)?.visibleFrame
        setFrameOrigin(NSWindowPositioning.centeredOrigin(
            windowSize: frame.size,
            anchorFrame: anchor.frame,
            visibleFrame: visibleFrame
        ))
    }
}

enum NSWindowPositioning {
    static func anchorWindow(excluding excluded: NSWindow?) -> NSWindow? {
        let candidates = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.windows
        return candidates.first { window in
            window !== excluded
                && window.isVisible
                && !(window is NSPanel)
                && window.canBecomeMain
        }
    }

    static func centeredOrigin(
        windowSize: NSSize,
        anchorFrame: NSRect,
        visibleFrame: NSRect?
    ) -> NSPoint {
        var origin = NSPoint(
            x: anchorFrame.midX - windowSize.width / 2,
            y: anchorFrame.midY - windowSize.height / 2
        )
        guard let visibleFrame else { return origin }
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - windowSize.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - windowSize.height)
        return origin
    }
}
