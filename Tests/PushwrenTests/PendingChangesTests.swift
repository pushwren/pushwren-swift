import Foundation
import XCTest
@testable import Pushwren

final class PendingChangesTests: XCTestCase {
    private func json(_ patch: DevicePatch) throws -> [String: Any] {
        let data = try JSONEncoder().encode(patch)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testAddThenRemoveSendsOnlyTheRemove() throws {
        var p = PendingChanges()
        p.addTags(["pro", "beta"])
        p.removeTags(["pro"])
        let body = try json(p.patch()!)
        XCTAssertEqual(body["addTags"] as? [String], ["beta"])
        XCTAssertEqual(body["removeTags"] as? [String], ["pro"])
        XCTAssertNil(body["userId"])
    }

    func testRemoveThenAddSendsOnlyTheAdd() throws {
        var p = PendingChanges()
        p.removeTags(["pro"])
        p.addTags(["pro"])
        let body = try json(p.patch()!)
        XCTAssertEqual(body["addTags"] as? [String], ["pro"])
        XCTAssertNil(body["removeTags"])
    }

    func testSetUserIDSendsTheSignatureAndClearSendsNull() throws {
        var p = PendingChanges()
        p.user = .set(id: "u_1", signature: String(repeating: "a", count: 64))
        XCTAssertEqual(try json(p.patch()!)["userId"] as? String, "u_1")
        XCTAssertEqual(try json(p.patch()!)["userIdSignature"] as? String, String(repeating: "a", count: 64))
        p.user = .clear
        let body = try json(p.patch()!)
        XCTAssertTrue(body.keys.contains("userId"))
        XCTAssertTrue(body["userId"] is NSNull)
        XCTAssertNil(body["userIdSignature"])
    }

    func testNothingPendingIsNoPatch() {
        XCTAssertNil(PendingChanges().patch())
    }

    func test120TagChangesGoOutAsTwoPatches() throws {
        var p = PendingChanges()
        p.addTags((0..<120).map { "t\($0)" })
        let first = p.patch()!
        XCTAssertEqual(first.addTags.count + first.removeTags.count, 98)
        p.clear(sent: first)
        let second = p.patch()!
        XCTAssertEqual(second.addTags.count, 22)
        p.clear(sent: second)
        XCTAssertNil(p.patch())
    }

    func testClearKeepsAChangeMadeAfterThePatchWasBuilt() {
        var p = PendingChanges()
        p.addTags(["a"])
        p.user = .set(id: "u_1", signature: nil)
        let sent = p.patch()!
        p.removeTags(["a"]) // made while the request was in flight
        p.user = .set(id: "u_2", signature: nil)
        p.clear(sent: sent)
        XCTAssertEqual(p.remove, ["a"])
        XCTAssertEqual(p.user, .set(id: "u_2", signature: nil))
    }
}
