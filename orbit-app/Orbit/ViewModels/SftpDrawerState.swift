import SwiftUI

/// Isolated state for the SFTP drawer to prevent drag events from triggering
/// full view-tree re-evaluation in AppState.
class SftpDrawerState: ObservableObject {
    @Published var tabId: String? = nil
    @Published var height: CGFloat = 280

    func toggle(for tab: String) {
        if tabId == tab {
            tabId = nil
        } else {
            tabId = tab
        }
    }

    func close() {
        tabId = nil
    }
}
