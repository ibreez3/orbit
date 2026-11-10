import XCTest
@testable import AgentKit

final class AgentExposureStoreTests: XCTestCase {
    func testDisabledServerIsNotExposedAndDefaultsToEnabled() {
        let suite = "AgentExposureStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentExposureStore(defaults: defaults)
        let server = AgentServerSummary(
            id: "id-a", name: "api", host: "h",
            port: 22, username: "u", folder: nil, tags: [], aiEnabled: true
        )
        XCTAssertTrue(store.isEnabled(serverId: "id-a"))
        store.setEnabled(false, serverId: "id-a")
        XCTAssertFalse(store.isEnabled(serverId: "id-a"))
        XCTAssertTrue(store.enabledServers(from: [server]).isEmpty)
    }
}
