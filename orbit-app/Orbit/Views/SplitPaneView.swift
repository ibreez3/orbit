import SwiftUI

struct SplitPaneView: View {
    let node: PaneNode
    let serverId: String
    let tabId: String
    let appState: AppState
    @EnvironmentObject var tabState: TabState

    var body: some View {
        switch node {
        case .leaf(let channelId):
            TerminalView(channelId: channelId, serverId: serverId, tabId: tabId, appState: appState)
                .overlay(
                    (tabState.tabs.first(where: { $0.id == tabId })?.focusedChannelId == channelId)
                        ? Color.accentColor.opacity(0.03)
                        : Color.clear
                )
                .onTapGesture {
                    appState.requestFocusPane(tabId: tabId, paneId: channelId)
                    if let tv = OrbitBridge.shared.terminalView(for: channelId) as? OrbitTerminalView {
                        tv.window?.makeFirstResponder(tv)
                    }
                }
        case .split(let splitId, let direction, let ratio, let first, let second):
            SplitContainer(direction: direction, ratio: ratio, splitId: splitId) { newRatio in
                appState.updatePaneRatio(tabId: tabId, splitId: splitId, newRatio: newRatio)
            } first: {
                SplitPaneView(node: first, serverId: serverId, tabId: tabId, appState: appState)
            } second: {
                SplitPaneView(node: second, serverId: serverId, tabId: tabId, appState: appState)
            }
            .id(splitId)
        }
    }
}

struct SplitContainer<First: View, Second: View>: View {
    let direction: SplitDirection
    let splitId: String
    let onRatioChange: (Double) -> Void
    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    // committedRatio: pane sizing ratio (stable during drag)
    // dragOffset: divider visual offset during drag (pixels, relative to committed position)
    @State private var committedRatio: Double
    @State private var dragOffset: CGFloat = 0
    @State private var dragging: Bool = false

    init(direction: SplitDirection, ratio: Double, splitId: String,
         onRatioChange: @escaping (Double) -> Void,
         @ViewBuilder first: () -> First,
         @ViewBuilder second: () -> Second) {
        self.direction = direction
        self.splitId = splitId
        self.onRatioChange = onRatioChange
        self._committedRatio = State(initialValue: ratio)
        self.first = first()
        self.second = second()
    }

    var body: some View {
        GeometryReader { geo in
            let isH = direction == .horizontal
            let total = isH ? geo.size.width : geo.size.height
            let baseSize = total * committedRatio
            // Divider visual position = base + drag offset, clamped
            let dividerPos = (baseSize + dragOffset).clamped(to: total * 0.1 ... total * 0.9)

            ZStack(alignment: isH ? .leading : .top) {
                // Pane contents — sized by committedRatio, stable during drag
                if isH {
                    HStack(spacing: 0) {
                        first
                            .frame(width: baseSize - 2)
                        Color.clear.frame(width: 4)
                        second
                    }
                } else {
                    VStack(spacing: 0) {
                        first
                            .frame(height: baseSize - 2)
                        Color.clear.frame(height: 4)
                        second
                    }
                }

                // Draggable divider overlay — moves visually during drag
                divider(isHorizontal: isH)
                    .position(
                        x: isH ? dividerPos : geo.size.width / 2,
                        y: isH ? geo.size.height / 2 : dividerPos
                    )
                    .gesture(dragGesture(geo: geo, isHorizontal: isH))
            }
        }
    }

    private func divider(isHorizontal: Bool) -> some View {
        Rectangle()
            .fill(dragging ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
            .frame(
                width: isHorizontal ? 4 : nil,
                height: isHorizontal ? nil : 4
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    if isHorizontal {
                        NSCursor.resizeLeftRight.set()
                    } else {
                        NSCursor.resizeUpDown.set()
                    }
                } else if !dragging {
                    NSCursor.arrow.set()
                }
            }
    }

    private func dragGesture(geo: GeometryProxy, isHorizontal: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    dragOffset = 0
                }
                let total = isHorizontal ? geo.size.width : geo.size.height
                let loc = isHorizontal ? value.location.x : value.location.y
                let desiredRatio = loc / total
                let baseSize = total * committedRatio
                // Calculate offset from committed position
                dragOffset = (desiredRatio * total) - baseSize
            }
            .onEnded { _ in
                dragging = false
                let total = isHorizontal ? geo.size.width : geo.size.height
                let newRatio = (total * committedRatio + dragOffset) / total
                let clamped = max(0.1, min(0.9, newRatio))
                committedRatio = clamped
                dragOffset = 0
                onRatioChange(clamped)
            }
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
