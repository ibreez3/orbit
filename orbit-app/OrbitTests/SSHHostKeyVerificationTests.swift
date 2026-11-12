import XCTest
@testable import Orbit

final class SSHHostKeyVerificationTests: XCTestCase {
    private func request(_ id: String = "first", previous: String? = nil, role: String = "direct") throws -> SSHHostKeyRequest {
        var object: [String: Any] = ["id": id, "host": "2001:db8::1", "port": 2222, "role": role,
                                    "algorithm": "Ed25519", "fingerprint": "SHA256:new"]
        object["previous_fingerprint"] = previous
        return try JSONDecoder().decode(SSHHostKeyRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testRequestShowsEndpointRoleAndBothFingerprints() throws {
        let unknown = try request()
        XCTAssertFalse(unknown.isChanged)
        XCTAssertEqual(unknown.endpoint, "[2001:db8::1]:2222")
        XCTAssertEqual(unknown.roleLabel, "直连服务器")
        let changed = try request(previous: "SHA256:old", role: "target")
        XCTAssertTrue(changed.isChanged)
        XCTAssertTrue(changed.details.contains("SHA256:old"))
        XCTAssertTrue(changed.details.contains("SHA256:new"))
        XCTAssertTrue(changed.details.contains("手动重试"))
        XCTAssertEqual(changed.roleLabel, "目标服务器（经跳板机）")
        XCTAssertEqual(try request(role: "jump").roleLabel, "跳板机")
    }

    @MainActor
    func testConcurrentNotificationsAreSerializedAndDuplicateIsIgnored() throws {
        let first = try request()
        let second = try request("second", role: "jump")
        var presented: [String] = []
        var resolved: [String] = []
        var controller: SSHHostKeyVerification!
        controller = SSHHostKeyVerification(present: { item in
            presented.append(item.id)
            if item.id == first.id {
                controller.enqueue(first)
                controller.enqueue(second)
                XCTAssertEqual(presented, [first.id])
            }
            return item.id == second.id
        }, resolve: { id, trust in
            resolved.append(id)
            XCTAssertEqual(trust, id == second.id)
        }, reportError: { _ in XCTFail("Unexpected error") })
        controller.enqueue(first)
        controller.enqueue(first)
        XCTAssertEqual(presented, [first.id, second.id])
        XCTAssertEqual(resolved, [first.id, second.id])
    }

    @MainActor
    func testTrustDefaultsToCancelAndChangedKeysRequireTwoConfirmations() throws {
        let unknown = try request()
        XCTAssertFalse(SSHHostKeyVerification.presentAlert(unknown, run: { alert in
            XCTAssertEqual(alert.buttons.first?.title, "取消连接")
            return .alertFirstButtonReturn
        }))
        XCTAssertTrue(SSHHostKeyVerification.presentAlert(unknown, run: { _ in .alertSecondButtonReturn }))
        let changed = try request(previous: "SHA256:old")
        var prompts = 0
        XCTAssertFalse(SSHHostKeyVerification.presentAlert(changed, run: { alert in
            prompts += 1
            XCTAssertTrue(alert.informativeText.contains("SHA256:old"))
            XCTAssertTrue(alert.informativeText.contains("SHA256:new"))
            return prompts == 1 ? .alertSecondButtonReturn : .alertFirstButtonReturn
        }))
        XCTAssertEqual(prompts, 2)
        prompts = 0
        XCTAssertTrue(SSHHostKeyVerification.presentAlert(changed, run: { _ in
            prompts += 1
            return .alertSecondButtonReturn
        }))
        XCTAssertEqual(prompts, 2)
    }

    @MainActor
    func testPersistenceFailureIsReported() throws {
        var errors: [String] = []
        let controller = SSHHostKeyVerification(present: { _ in true }, resolve: { _, _ in
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "stale request"])
        }, reportError: { errors.append($0) })
        controller.enqueue(try request())
        XCTAssertEqual(errors, ["stale request"])
    }
}
