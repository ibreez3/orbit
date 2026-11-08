import XCTest
@testable import Orbit

final class OrbitBridgeCallbackBufferTests: XCTestCase {
    func testDataBeforeHandlerIsDeliveredInOriginalOrder() {
        let bridge = OrbitBridge.shared
        let sessionId = "test-data-\(UUID().uuidString)"
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        var received: [Data] = []
        defer { bridge.removeSSHHandlers(sessionId: sessionId) }

        bridge.handleSSHData(sessionId: sessionId, data: first)
        bridge.handleSSHData(sessionId: sessionId, data: second)
        bridge.setSSHHandlers(
            sessionId: sessionId,
            dataHandler: { received.append($0) },
            closedHandler: {}
        )

        XCTAssertEqual(received, [first, second])
    }

    func testCloseBeforeHandlerIsDeliveredOnceAfterEarlierData() {
        let bridge = OrbitBridge.shared
        let sessionId = "test-close-\(UUID().uuidString)"
        var events: [String] = []
        defer { bridge.removeSSHHandlers(sessionId: sessionId) }

        bridge.handleSSHData(sessionId: sessionId, data: Data("before-close".utf8))
        bridge.handleSSHClosed(sessionId: sessionId)
        bridge.setSSHHandlers(
            sessionId: sessionId,
            dataHandler: { _ in events.append("data") },
            closedHandler: { events.append("close") }
        )
        bridge.setSSHHandlers(
            sessionId: sessionId,
            dataHandler: { _ in events.append("second-data") },
            closedHandler: { events.append("second-close") }
        )

        XCTAssertEqual(events, ["data", "close"])
    }

    func testCloseIsDeliveredAtMostOnceWithRegisteredHandlers() {
        let bridge = OrbitBridge.shared
        let sessionId = "test-duplicate-close-\(UUID().uuidString)"
        var closeCount = 0
        defer { bridge.removeSSHHandlers(sessionId: sessionId) }

        bridge.setSSHHandlers(
            sessionId: sessionId,
            dataHandler: { _ in },
            closedHandler: { closeCount += 1 }
        )
        bridge.handleSSHClosed(sessionId: sessionId)
        bridge.handleSSHClosed(sessionId: sessionId)

        XCTAssertEqual(closeCount, 1)
    }

    func testRemovingHandlersDiscardsUnmatchedEvents() {
        let bridge = OrbitBridge.shared
        let sessionId = "test-remove-\(UUID().uuidString)"
        var events: [String] = []
        defer { bridge.removeSSHHandlers(sessionId: sessionId) }

        bridge.handleSSHData(sessionId: sessionId, data: Data("discard".utf8))
        bridge.handleSSHClosed(sessionId: sessionId)
        bridge.removeSSHHandlers(sessionId: sessionId)
        bridge.handleSSHData(sessionId: sessionId, data: Data("late".utf8))
        bridge.handleSSHClosed(sessionId: sessionId)
        bridge.setSSHHandlers(
            sessionId: sessionId,
            dataHandler: { _ in events.append("data") },
            closedHandler: { events.append("close") }
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testRemovingHandlersDuringDrainCancelsRemainingExtractedEvents() {
        let bridge = OrbitBridge.shared
        let sessionId = "test-cancel-drain-\(UUID().uuidString)"
        var received: [String] = []
        defer { bridge.removeSSHHandlers(sessionId: sessionId) }

        bridge.handleSSHData(sessionId: sessionId, data: Data("first".utf8))
        bridge.handleSSHData(sessionId: sessionId, data: Data("second".utf8))
        bridge.setSSHHandlers(
            sessionId: sessionId,
            dataHandler: { data in
                received.append(String(decoding: data, as: UTF8.self))
                if received.count == 1 {
                    bridge.removeSSHHandlers(sessionId: sessionId)
                }
            },
            closedHandler: {}
        )

        XCTAssertEqual(received, ["first"])
    }
}
