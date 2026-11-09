import XCTest
@testable import AgentKit

final class AgentServerDirectoryTests: XCTestCase {
    func testResolvesByIdThenUniqueNameThenHostAndRejectsAmbiguous() {
        let first = AgentServerSummary(
            id: "id-a", name: "api", host: "10.0.0.1",
            port: 22, username: "u", folder: nil, tags: [], aiEnabled: true
        )
        let second = AgentServerSummary(
            id: "id-b", name: "api", host: "10.0.0.2",
            port: 22, username: "u", folder: nil, tags: [], aiEnabled: true
        )
        let directory = AgentServerDirectory(servers: [first, second])
        XCTAssertEqual(directory.resolve("id-a"), .resolved(first))
        XCTAssertEqual(directory.resolve("10.0.0.1"), .resolved(first))
        guard case .ambiguous(let candidates) = directory.resolve("api") else {
            return XCTFail("expected ambiguous name")
        }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(directory.resolve("missing"), .notFound)
    }

    func testListReturnsOnlyExposedServers() {
        let exposed = AgentServerSummary(
            id: "id-a", name: "api", host: "10.0.0.1",
            port: 22, username: "u", folder: nil, tags: [], aiEnabled: true
        )
        let hidden = AgentServerSummary(
            id: "id-b", name: "db", host: "10.0.0.2",
            port: 22, username: "u", folder: nil, tags: [], aiEnabled: false
        )
        let directory = AgentServerDirectory(servers: [exposed, hidden])
        XCTAssertEqual(directory.list(), [exposed])
    }
}
