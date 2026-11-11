import XCTest
@testable import Orbit

final class ReleaseNotesMarkdownTests: XCTestCase {
    func testHeadingsParagraphsAndLists() {
        let blocks = ReleaseNotesMarkdownParser.parse("""
        # 标题
        这是第一段。
        这是第二段。

        ## 新增
        - 支持自动更新
        - 关于窗口
        1. 第一步
        2. 第二步

        > 提示
        ---
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "标题"),
            .paragraph("这是第一段。 这是第二段。"),
            .heading(level: 2, text: "新增"),
            .bullet("支持自动更新"),
            .bullet("关于窗口"),
            .numbered(1, "第一步"),
            .numbered(2, "第二步"),
            .quote("提示"),
            .divider
        ])
    }

    func testFencedCodeBlockIncludingUnclosedFence() {
        XCTAssertEqual(
            ReleaseNotesMarkdownParser.parse("```\nlet a = 1\n```"),
            [.code("let a = 1")]
        )
        XCTAssertEqual(
            ReleaseNotesMarkdownParser.parse("```\nlet a = 1"),
            [.code("let a = 1")]
        )
    }

    func testEmptyAndChinese() {
        XCTAssertEqual(ReleaseNotesMarkdownParser.parse(""), [])
        XCTAssertEqual(
            ReleaseNotesMarkdownParser.parse("修复了中文输入问题。"),
            [.paragraph("修复了中文输入问题。")]
        )
    }
}
