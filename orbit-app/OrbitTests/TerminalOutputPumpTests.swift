import XCTest
@testable import Orbit

final class TerminalOutputPumpTests: XCTestCase {
    @MainActor
    func testLogBurstYieldsMainQueueBeforeFinishing() {
        let terminal = OrbitTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let line = "\u{1b}[32mINFO\u{1b}[0m " + String(repeating: "a", count: 140) + "\r\n"
        let expected = Data(String(repeating: line, count: 1352).utf8)
        let done = expectation(description: "burst drained")
        let yielded = expectation(description: "main queue serviced during burst")
        var received = Data()
        let pump = TerminalOutputPump { chunk, _ in
            if received.isEmpty {
                DispatchQueue.main.async {
                    XCTAssertLessThan(received.count, expected.count)
                    yielded.fulfill()
                }
            }
            TerminalOutputPump.feed(chunk, to: terminal)
            received.append(chunk)
            if received.count == expected.count { done.fulfill() }
        }
        pump.enqueue(expected)
        wait(for: [yielded, done], timeout: 10)
        XCTAssertEqual(received, expected)
    }

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
