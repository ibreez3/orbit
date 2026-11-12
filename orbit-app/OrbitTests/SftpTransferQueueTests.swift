import XCTest
@testable import Orbit

private final class TransferClient: SftpTransferClient {
    var run: (SftpTransferRequest, @escaping (UInt64, UInt64) -> Void) throws -> Void = { _, _ in }
    var cancelled: [String] = []
    func reserveSftpTransfer() throws -> String { UUID().uuidString }
    func cancelSftpTransfer(_ id: String) { cancelled.append(id) }
    func runSftpTransfer(_ request: SftpTransferRequest, progress: @escaping (UInt64, UInt64) -> Void) throws { try run(request, progress) }
}

@MainActor
final class SftpTransferQueueTests: XCTestCase {
    private func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate())
    }

    func testByteProgressDoesNotFinishBeforeAtomicCommitAndQueueIsSerial() async {
        let client = TransferClient()
        let gate = DispatchSemaphore(value: 0)
        client.run = { _, progress in
            progress(100, 100)
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
        }
        let queue = SftpTransferQueue(serverId: "server", client: client)
        queue.enqueue(local: "/source", remote: "/target", upload: true)
        queue.enqueue(local: "/next", remote: "/next", upload: true)
        await eventually { queue.items[0].transferred == 100 }
        XCTAssertEqual(queue.items[0].status, .running)
        XCTAssertEqual(queue.items[1].status, .queued)
        queue.cancel(queue.items[1].id)
        gate.signal()
        await eventually { queue.items[0].status == .completed }
        XCTAssertEqual(queue.items[1].status, .cancelled)
        XCTAssertEqual(queue.revision, 1)
    }

    func testConflictRequiresExplicitOverwriteAndRetriesGetNewIDs() async {
        let client = TransferClient()
        client.run = { request, _ in
            if !request.overwrite { throw SftpTransferError.conflict }
        }
        let queue = SftpTransferQueue(serverId: "server", client: client)
        queue.enqueue(local: "/source", remote: "/target", upload: true)
        let originalId = queue.items[0].backendId
        await eventually { queue.items[0].status == .conflict }
        queue.retry(queue.items[0].id)
        await eventually { queue.items[0].status == .conflict }
        queue.retry(queue.items[0].id, overwrite: true)
        XCTAssertNotEqual(queue.items[0].backendId, originalId)
        await eventually { queue.items[0].status == .completed }
    }

    func testCancellationCallsBackendAndDoesNotPretendFinishedEarly() async {
        let client = TransferClient()
        let gate = DispatchSemaphore(value: 0)
        client.run = { _, _ in
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            throw SftpTransferError.cancelled
        }
        let queue = SftpTransferQueue(serverId: "server", client: client)
        queue.enqueue(local: "/source", remote: "/target", upload: false)
        let backendId = queue.items[0].backendId!
        queue.cancel(queue.items[0].id)
        XCTAssertEqual(client.cancelled, [backendId])
        XCTAssertEqual(queue.items[0].status, .cancelling)
        gate.signal()
        await eventually { queue.items[0].status == .cancelled }
        XCTAssertEqual(queue.revision, 0)
    }

    func testFailureCanRetryAndClearingDoesNotDiscardActiveTasks() async {
        let client = TransferClient()
        client.run = { _, _ in throw SftpTransferError.failed("disk full") }
        let queue = SftpTransferQueue(serverId: "server", client: client)
        queue.enqueue(local: "/source", remote: "/target", upload: true)
        await eventually { queue.items[0].status == .failed("disk full") }
        client.run = { _, _ in }
        queue.retry(queue.items[0].id)
        queue.clearFinished()
        XCTAssertEqual(queue.items.count, 1)
        await eventually { queue.items[0].status == .completed }
        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
    }
}
