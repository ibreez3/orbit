import SwiftUI

struct SftpDrawerView: View {
    let tab: TabItem
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            SftpView(tab: tab)
        }
        .frame(height: appState.sftpDrawerHeight)
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
                Button(action: { appState.sftpDrawerTabId = nil }) {
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
                    let newHeight = appState.sftpDrawerHeight - value.translation.height
                    appState.sftpDrawerHeight = max(160, min(newHeight, 600))
                }
        )
    }
}
