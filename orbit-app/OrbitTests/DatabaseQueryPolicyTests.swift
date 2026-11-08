import XCTest
@testable import Orbit

final class DatabaseQueryPolicyTests: XCTestCase {
    func testAddsLimitToPlainSelect() {
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(
                to: "SELECT * FROM users",
                limit: 200,
                enabled: true
            ),
            "SELECT * FROM users\nLIMIT 200"
        )
    }

    func testStripsTrailingSemicolonBeforeAddingLimit() {
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(
                to: "SELECT * FROM users;",
                limit: 50,
                enabled: true
            ),
            "SELECT * FROM users\nLIMIT 50"
        )
    }

    func testKeepsExistingTopLevelLimit() {
        let sql = "SELECT * FROM users LIMIT 10"
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(to: sql, limit: 200, enabled: true),
            sql
        )
    }

    func testIgnoresLimitInsideSubqueryOrStringLiteral() {
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(
                to: "SELECT * FROM users WHERE id IN (SELECT id FROM admins LIMIT 3)",
                limit: 200,
                enabled: true
            ),
            "SELECT * FROM users WHERE id IN (SELECT id FROM admins LIMIT 3)\nLIMIT 200"
        )
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(
                to: "SELECT * FROM logs WHERE message = 'limit reached'",
                limit: 200,
                enabled: true
            ),
            "SELECT * FROM logs WHERE message = 'limit reached'\nLIMIT 200"
        )
    }

    func testLeavesNonSelectStatementsAlone() {
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(
                to: "UPDATE users SET active = 1",
                limit: 200,
                enabled: true
            ),
            "UPDATE users SET active = 1"
        )
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(
                to: "PRAGMA table_info(users)",
                limit: 200,
                enabled: true
            ),
            "PRAGMA table_info(users)"
        )
    }

    func testHonorsDisabledSetting() {
        let sql = "SELECT * FROM users"
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(to: sql, limit: 200, enabled: false),
            sql
        )
    }

    func testSkipsSelectIntoAndLockingClauses() {
        let selectInto = "SELECT * INTO archived_users FROM users"
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(to: selectInto, limit: 200, enabled: true),
            selectInto
        )
        let forUpdate = "SELECT * FROM users FOR UPDATE"
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(to: forUpdate, limit: 200, enabled: true),
            forUpdate
        )
    }

    func testDoesNotMistakeIdentifierForKeyword() {
        XCTAssertEqual(
            DatabaseQueryPolicy.applyingAutoLimit(
                to: "SELECT limit_value FROM settings",
                limit: 200,
                enabled: true
            ),
            "SELECT limit_value FROM settings\nLIMIT 200"
        )
    }
}
