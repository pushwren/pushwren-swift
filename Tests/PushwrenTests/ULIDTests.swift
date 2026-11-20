import XCTest
@testable import Pushwren

final class ULIDTests: XCTestCase {
    func testULIDHas26CrockfordCharacters() {
        let id = ULID.make()
        XCTAssertEqual(id.count, 26)
        let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(id.allSatisfy { crockford.contains($0) }, id)
        XCTAssertTrue("01234567".contains(id.first!), "the first character holds at most 3 bits")
    }

    func testULIDsSortByTime() {
        let earlier = ULID.make(now: Date(timeIntervalSince1970: 1_795_000_000.000))
        let later = ULID.make(now: Date(timeIntervalSince1970: 1_795_000_000.001))
        XCTAssertLessThan(earlier, later)
        XCTAssertEqual(ULID.make(now: Date(timeIntervalSince1970: 0)).prefix(10), "0000000000")
    }

    func testULIDsAreUnique() {
        XCTAssertEqual(Set((0..<10_000).map { _ in ULID.make() }).count, 10_000)
    }

    func testDeviceIDsAreDevPrefixedULIDs() {
        let id = ULID.deviceID()
        XCTAssertTrue(id.hasPrefix("dev_"))
        XCTAssertNotNil(id.range(of: "^dev_[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression))
    }
}
