import XCTest
@testable import Orbit

final class PaneNavigationTests: XCTestCase {
    private var tree: PaneNode {
        .split(
            id: "root",
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(channelId: "left"),
            second: .split(
                id: "nested",
                direction: .vertical,
                ratio: 0.5,
                first: .leaf(channelId: "top"),
                second: .leaf(channelId: "bottom")
            )
        )
    }

    func testMovesRightIntoFirstLeafOfSiblingSubtree() {
        XCTAssertEqual(tree.neighbor(of: "left", direction: .right), "top")
    }

    func testMovesLeftAcrossNestedSplits() {
        XCTAssertEqual(tree.neighbor(of: "top", direction: .left), "left")
        XCTAssertEqual(tree.neighbor(of: "bottom", direction: .left), "left")
    }

    func testMovesVerticallyWithinNestedSplit() {
        XCTAssertEqual(tree.neighbor(of: "top", direction: .down), "bottom")
        XCTAssertEqual(tree.neighbor(of: "bottom", direction: .up), "top")
    }

    func testReturnsNilWhenThereIsNoPaneInThatDirection() {
        XCTAssertNil(tree.neighbor(of: "left", direction: .down))
        XCTAssertNil(tree.neighbor(of: "left", direction: .up))
        XCTAssertNil(tree.neighbor(of: "bottom", direction: .right))
        XCTAssertNil(PaneNode.leaf(channelId: "only").neighbor(of: "only", direction: .left))
    }
}
