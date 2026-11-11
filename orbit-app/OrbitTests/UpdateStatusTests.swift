import XCTest
import Sparkle
@testable import Orbit

final class UpdateStatusTests: XCTestCase {
    @MainActor
    func testExpectedSparkleCycleErrorsDoNotBecomeFailures() {
        for code in [SUError.noUpdateError.rawValue, SUError.installationCanceledError.rawValue] {
            XCTAssertTrue(UpdateManager.isExpectedCycleEnd(NSError(domain: SUSparkleErrorDomain, code: Int(code))))
            XCTAssertFalse(UpdateManager.isExpectedCycleEnd(NSError(domain: NSURLErrorDomain, code: Int(code))))
        }
        XCTAssertFalse(UpdateManager.isExpectedCycleEnd(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    func testNoUpdateReasonMapsToStatus() {
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .latest, latest: nil)),
            .upToDate
        )
        let latest = AvailableUpdate(
            shortVersion: "0.0.11", build: "12", title: "Orbit 0.0.11",
            notes: nil, notesFormat: nil, fullNotesURL: nil, releasePageURL: nil
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .newerThanFeed, latest: latest)),
            .newerThanFeed(latest: latest)
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .systemTooOld, latest: nil)),
            .failed("线上稳定版需要更高版本的 macOS")
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .systemTooNew, latest: nil)),
            .failed("线上稳定版暂不支持当前 macOS 版本")
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .hardwareUnsupported, latest: nil)),
            .failed("线上稳定版不支持当前硬件架构")
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .unknown, latest: nil)),
            .upToDate
        )
    }

    func testFoundAndFailureTransitions() {
        let update = AvailableUpdate(
            shortVersion: "0.0.12", build: "13", title: "Orbit 0.0.12",
            notes: "### 新增\n- 关于窗口", notesFormat: "markdown",
            fullNotesURL: URL(string: "https://example.com/releases/tag/v0.0.12"),
            releasePageURL: nil
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .found(update)),
            .updateAvailable(update)
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .failure("网络错误")),
            .failed("网络错误")
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.updateAvailable(update), event: .finished),
            .updateAvailable(update)
        )
    }

    func testDisplayText() {
        XCTAssertEqual(
            AppVersion(shortVersion: "0.0.11", build: "12").displayText,
            "版本 0.0.11 (12)"
        )
        let update = AvailableUpdate(
            shortVersion: "0.0.12", build: "13", title: "Orbit 0.0.12",
            notes: nil, notesFormat: nil, fullNotesURL: nil, releasePageURL: nil
        )
        XCTAssertTrue(UpdateStatus.updateAvailable(update).statusText.contains("0.0.12"))
        XCTAssertTrue(UpdateStatus.newerThanFeed(latest: update).statusText.contains("0.0.12"))
    }
}
