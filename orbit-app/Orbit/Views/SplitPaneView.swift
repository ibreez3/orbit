import SwiftUI

struct SplitPaneView: View {
    let node: PaneNode
    let serverId: String
    let tabId: String
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch node {
        case .leaf(let channelId):
            TerminalView(channelId: channelId, serverId: serverId, tabId: tabId)
                .overlay(
                    (appState.tabs.first(where: { $0.id == tabId })?.focusedChannelId == channelId)
                        ? Color.accentColor.opacity(0.03)
                        : Color.clear
                )
                .onTapGesture {
                    if let idx = appState.tabs.firstIndex(where: { $0.id == tabId }) {
                        appState.tabs[idx].focusedChannelId = channelId
                    }
                }
        case .split(let splitId, let direction, let ratio, let first, let second):
            SplitContainer(direction: direction, ratio: ratio, splitId: splitId) { newRatio in
                appState.updatePaneRatio(tabId: tabId, splitId: splitId, newRatio: newRatio)
            } first: {
                SplitPaneView(node: first, serverId: serverId, tabId: tabId)
            } second: {
                SplitPaneView(node: second, serverId: serverId, tabId: tabId)
            }
            .id(splitId)
        }
    }
}

struct SplitContainer<First: View, Second: View>: View {
    let direction: SplitDirection
    @State var ratio: Double
    let splitId: String
    let onRatioChange: (Double) -> Void
    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    @State private var dragging = false

    init(direction: SplitDirection, ratio: Double, splitId: String,
         onRatioChange: @escaping (Double) -> Void,
         @ViewBuilder first: () -> First,
         @ViewBuilder second: () -> Second) {
        self.direction = direction
        self._ratio = State(initialValue: ratio)
        self.splitId = splitId
        self.onRatioChange = onRatioChange
        self.first = first()
        self.second = second()
    }

    var body: some View {
        GeometryReader { geo in
            if direction == .horizontal {
                hSplit(geo)
            } else {
                vSplit(geo)
            }
        }
    }

    private func hSplit(_ geo: GeometryProxy) -> some View {
        let dividerX = geo.size.width * ratio
        return HStack(spacing: 0) {
            first
                .frame(width: dividerX - 2)
            divider
                .frame(width: 4)
                .contentShape(Rectangle())
                .gesture(dragGesture(geo, isHorizontal: true))
            second
                .frame(width: geo.size.width - dividerX - 2)
        }
    }

    private func vSplit(_ geo: GeometryProxy) -> some View {
        let dividerY = geo.size.height * ratio
        return VStack(spacing: 0) {
            first
                .frame(height: dividerY - 2)
            divider
                .frame(height: 4)
                .contentShape(Rectangle())
                .gesture(dragGesture(geo, isHorizontal: false))
            second
                .frame(height: geo.size.height - dividerY - 2)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(dragging ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor))
    }

    private func dragGesture(_ geo: GeometryProxy, isHorizontal: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                dragging = true
                let total = isHorizontal ? geo.size.width : geo.size.height
                let loc = isHorizontal ? value.location.x : value.location.y
                ratio = max(0.1, min(0.9, loc / total))
            }
            .onEnded { _ in
                dragging = false
                onRatioChange(ratio)
            }
    }
}
