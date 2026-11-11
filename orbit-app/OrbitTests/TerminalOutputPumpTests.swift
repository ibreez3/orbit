import XCTest
@testable import Orbit

final class TerminalOutputPumpTests: XCTestCase {
    func testFragmentedOutputPreservesEveryByteAndOrder() {
        let done = expectation(description: "all output drained")
        let expected = Data((0..<10000).map { UInt8($0 % 256) })
        var received = Data()
        let pump = TerminalOutputPump(chunkBytes: 73, frameInterval: 0, maxChunksPerFrame: 4) { data, _ in
            XCTAssertTrue(Thread.isMainThread)
            received.append(data)
            if received.count == expected.count { done.fulfill() }
        }
        DispatchQueue.global().async {
            for start in stride(from: 0, to: expected.count, by: 41) {
                pump.enqueue(expected.subdata(in: start..<min(start + 41, expected.count)))
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(received, expected)
        pump.invalidate()
    }

    func testInvalidationDropsPendingDeliveryAndRejectsLaterEnqueues() {
        let unexpected = expectation(description: "invalidated output must not be delivered")
        unexpected.isInverted = true
        let pump = TerminalOutputPump { _, _ in unexpected.fulfill() }
        pump.invalidate()
        pump.enqueue(Data("ignored".utf8))
        wait(for: [unexpected], timeout: 0.1)
    }
}
