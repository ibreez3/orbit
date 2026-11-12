import SwiftUI

struct SftpDrawerView: View {
    let tab: TabItem
    let appState: AppState
    @EnvironmentObject var drawerState: SftpDrawerState
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            SftpView(tab: tab, appState: appState, compact: true)
        }
        .frame(height: drawerState.height)
        .background(.ultraThinMaterial)
    }

    private var dragHandle: some View {
        VStack(spacing: 4) {
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 4)

            HStack {
                Text("SFTP · \(tab.serverName)")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(action: { drawerState.close() }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    if dragStartHeight == nil { dragStartHeight = drawerState.height }
                    let newHeight = (dragStartHeight ?? drawerState.height) - value.translation.height
                    drawerState.height = max(360, min(newHeight, 600))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
    }
}
