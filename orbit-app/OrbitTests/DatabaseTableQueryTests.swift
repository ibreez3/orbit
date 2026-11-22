import SQLite3
import XCTest
@testable import Orbit

final class DatabaseTableQueryTests: XCTestCase {
    private var db: OpaquePointer?

    override func setUpWithError() throws {
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        sqlite3_close(db)
    }

    func run(_ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: String(cString: sqlite3_errmsg(db)), code: 1)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { i in
                sqlite3_column_text(statement, i).map { String(cString: $0) }
            })
            code = sqlite3_step(statement)
        }
        XCTAssertEqual(code, SQLITE_DONE)
        return rows
    }

    func testPagingEditingAndRelationshipsInSQLite() throws {
        let fields = ["tenant", "id", "message"].enumerated().map { i, name in
            DatabaseColumnSchema(name: name, db_type: i < 2 ? "INTEGER" : "TEXT", nullable: i == 2,
                                 primary_key: i < 2, default_value: nil, auto_generated: false)
        }
        let query = DatabaseTableQuery(engine: "remote_sqlite", table: DatabaseTableSchema(name: "events", columns: fields))
        _ = try run("CREATE TABLE tenants (id INTEGER PRIMARY KEY)")
        _ = try run("INSERT INTO tenants VALUES(1),(2)")
        _ = try run("CREATE TABLE events (tenant INTEGER REFERENCES tenants, id INTEGER, message TEXT, PRIMARY KEY (tenant,id))")
        _ = try run("WITH RECURSIVE ids(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM ids WHERE n<500) INSERT INTO events SELECT 1,n,NULL FROM ids")
        XCTAssertEqual(try run(query.page(0)).count, 500)
        XCTAssertTrue(try run(query.page(1)).isEmpty)
        _ = try run("INSERT INTO events VALUES(2,1,NULL)")
        XCTAssertEqual(try run(query.page(0)).count, 501)
        let row = try XCTUnwrap(run(query.page(1)).first)
        XCTAssertEqual(row.map(query.value), ["2", "1", nil])
        let text = "O'Brien\n\u{1f}__ORBIT_SQLITE_NULL__\\" + String(repeating: "日志", count: 4096)
        let update = try XCTUnwrap(query.update(2, row: row, newValue: text))
        _ = try run(update)
        XCTAssertEqual(sqlite3_changes(db), 1)
        let edited = try XCTUnwrap(run(query.page(1)).first)
        XCTAssertEqual(query.value(edited[2]), text)
        _ = try run(update)
        XCTAssertEqual(sqlite3_changes(db), 0)
        _ = try run(XCTUnwrap(query.update(2, row: edited, newValue: "")))
        let empty = try XCTUnwrap(run(query.page(1)).first)
        XCTAssertEqual(query.value(empty[2]), "")
        _ = try run(XCTUnwrap(query.update(2, row: empty, newValue: nil)))
        _ = try run(query.insert([0: "2", 1: "2", 2: "new"]))
        let matches = try run(query.page(0, filter: .init(column: 2, text: "ew"), sorting: 1, descending: true))
        XCTAssertEqual(matches.count, 1)
        _ = try run(XCTUnwrap(query.delete(matches[0])))
        XCTAssertEqual(sqlite3_changes(db), 1)
        XCTAssertEqual(try run(query.count(nil)), [["501"]])
        XCTAssertNil(query.update(0, row: row, newValue: "3"))
        XCTAssertFalse(query.canEdit(2, row: [nil, row[1], row[2]]))
        XCTAssertEqual(try run(DatabaseTableQuery.relationships("remote_sqlite")), [["events","tenant","tenants","id"]])
    }

    func testNullableTimestampUsesSQLNullAndPreservesInsertDefaults() throws {
        let fields = ["id", "created_at", "deleted_at"].enumerated().map { i, name in
            DatabaseColumnSchema(name: name, db_type: i == 0 ? "INTEGER" : "DATETIME", nullable: i == 2,
                                 primary_key: i == 0, default_value: nil, auto_generated: false)
        }
        let query = DatabaseTableQuery(engine: "remote_sqlite", table: DatabaseTableSchema(name: "events", columns: fields))
        _ = try run("CREATE TABLE events(id INTEGER PRIMARY KEY, created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, deleted_at DATETIME DEFAULT CURRENT_TIMESTAMP)")
        _ = try run(query.insert([0: "1"]))
        let row = try XCTUnwrap(run(query.page(0)).first)
        XCTAssertNotNil(query.value(row[2]))
        XCTAssertNil(query.update(1, row: row, newValue: nil))
        _ = try run(XCTUnwrap(query.update(2, row: row, newValue: nil)))
        XCTAssertEqual(sqlite3_changes(db), 1)
        _ = try run(query.insert([0: "2", 2: nil]))
        XCTAssertEqual(try run("SELECT deleted_at IS NULL FROM events ORDER BY id"), [["1"], ["1"]])
    }

    func testCompositeIndexCanBeListedAndDroppedWithoutRemovingConstraint() throws {
        let columns = ["a", "b"].map { DatabaseColumnSchema(name: $0, db_type: "TEXT", nullable: true,
                                                           primary_key: false, default_value: nil, auto_generated: false) }
        let query = DatabaseTableQuery(engine: "remote_sqlite", table: DatabaseTableSchema(name: "event log", columns: columns))
        _ = try run("CREATE TABLE \"event log\"(a TEXT UNIQUE, b TEXT)")
        let sql = try XCTUnwrap(query.createIndex("by \"time\"", fields: ["b", "a"], unique: true))
        _ = try run(sql)
        let result = DatabaseQueryResult(columns: [], rows: try run(query.indexListSQL), affected_rows: 0, elapsed_ms: 0, message: "")
        let indexes = query.indexes(result)
        let added = try XCTUnwrap(indexes.first { !$0.protected })
        XCTAssertTrue(added.definition.contains("\"b\", \"a\""))
        XCTAssertNil(query.dropIndex(try XCTUnwrap(indexes.first { $0.protected })))
        _ = try run(XCTUnwrap(query.dropIndex(added)))
        XCTAssertEqual(try run(query.indexListSQL).count, 1)
    }

    func testCursorMatchesOffsetsWithCompositeKeysNullsAndTies() throws {
        let columns = ["tenant", "item", "rank"].enumerated().map { i, name in
            DatabaseColumnSchema(name: name, db_type: "INTEGER", nullable: i == 2,
                                 primary_key: i < 2, default_value: nil, auto_generated: false)
        }
        let query = DatabaseTableQuery(engine: "remote_sqlite", table: DatabaseTableSchema(name: "items", columns: columns))
        _ = try run("CREATE TABLE items(tenant INTEGER NOT NULL,item INTEGER NOT NULL,rank INTEGER,PRIMARY KEY(tenant,item))")
        _ = try run("WITH RECURSIVE ids(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM ids WHERE n<1102) INSERT INTO items SELECT n%3,n/3,CASE WHEN n%2=0 THEN NULL ELSE n%5 END FROM ids")
        for sort in [nil, 0, 2] as [Int?] {
            for desc in [false, true] {
                var pages: [[[String?]]] = []
                for i in 0...2 {
                    let result = try run(query.page(i, sorting: sort, descending: desc))
                    pages.append(Array(result.prefix(500)))
                }
                for i in 1...2 {
                    let forward = try XCTUnwrap(query.adjacentPage(from: XCTUnwrap(pages[i-1].last), backwards: false, sorting: sort, descending: desc))
                    let backward = try XCTUnwrap(query.adjacentPage(from: XCTUnwrap(pages[i].first), backwards: true, sorting: sort, descending: desc))
                    XCTAssertEqual(Array(try run(forward).prefix(500)), pages[i])
                    XCTAssertEqual(Array(try run(backward).prefix(500).reversed()), pages[i-1])
                }
                let tail = try run(query.tailPage(count: 1103, filter: nil, sorting: sort, descending: desc))
                XCTAssertEqual(Array(tail.reversed()), pages[2])
            }
        }
        let exact = DatabaseTableQuery.Filter(column: 0, text: "1", mode: .exact)
        XCTAssertEqual(try run(query.count(exact)), [["368"]])
        let boundary = try XCTUnwrap(run(query.page(0, filter: exact)).first)
        let refresh = try XCTUnwrap(query.adjacentPage(from: boundary, backwards: false, filter: exact, includingBoundary: true))
        XCTAssertEqual(try run(refresh), try run(query.page(0, filter: exact)))
    }

    func testIndexedEditPreservesStorageClassAndOriginalValue() throws {
        let fields = ["id","note"].enumerated().map { i, name in
            DatabaseColumnSchema(name: name, db_type: "", nullable: false, primary_key: i == 0, default_value: nil, auto_generated: false)
        }
        let query = DatabaseTableQuery(engine: "remote_sqlite", table: DatabaseTableSchema(name: "items", columns: fields))
        _ = try run("CREATE TABLE items(id PRIMARY KEY NOT NULL, note TEXT COLLATE NOCASE)")
        _ = try run("INSERT INTO items VALUES(1,'a'),('1','a'),(X'31','a')")
        for row in try run(query.page(0)) {
            let sql = try XCTUnwrap(query.update(1, row: row, newValue: "A"))
            XCTAssertTrue(try run("EXPLAIN QUERY PLAN " + sql).contains { ($0.last ?? nil)?.contains("SEARCH") == true })
            _ = try run(sql)
            XCTAssertEqual(sqlite3_changes(db), 1)
            _ = try run(sql)
            XCTAssertEqual(sqlite3_changes(db), 0)
        }
        XCTAssertEqual(try run("SELECT count(*) FROM items WHERE note COLLATE BINARY='A'"), [["3"]])
    }
}
