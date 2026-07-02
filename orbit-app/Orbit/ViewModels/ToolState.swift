import SwiftUI

final class ToolState: ObservableObject {
    @Published var activeTool: BoundToolState?
    @Published var floatingToolWidth: CGFloat = 390
    @Published var floatingToolHeight: CGFloat = 460
    @Published var pendingContextSwitchTabId: String?
    @Published var pendingContextSwitchMessage: String?
    @Published var activeSftpTransferTabIds: Set<String> = []
    @Published var dockerPanelSnapshots: [String: DockerPanelSnapshot] = [:]
    @Published var aiPanelOpen: Bool = false
}
