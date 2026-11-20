import XCTest
@testable import Pushwren

final class ApsEnvironmentTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testProfilePlistIsFoundInsideTheSignedEnvelope() throws {
        let plist = try XCTUnwrap(EnvironmentDetector.parseProfile(try fixture("ios-development.mobileprovision")))
        XCTAssertEqual(plist["Name"] as? String, "Fixture")
    }

    func testDevelopmentProfileIsSandbox() throws {
        let r = EnvironmentDetector.fromProfile(try fixture("ios-development.mobileprovision"), platform: .ios)
        XCTAssertEqual(r.environment, .sandbox)
        XCTAssertNil(r.warning)
    }

    func testProductionProfileIsProduction() throws {
        let r = EnvironmentDetector.fromProfile(try fixture("ios-production.mobileprovision"), platform: .ipados)
        XCTAssertEqual(r.environment, .production)
    }

    func testNoProfileOnIOSIsProduction() {
        // TestFlight and App Store builds carry no embedded profile.
        let r = EnvironmentDetector.fromProfile(nil, platform: .ios)
        XCTAssertEqual(r.environment, .production)
        XCTAssertNil(r.warning)
    }

    func testProfileWithoutApsEntitlementIsMissingWithWarning() throws {
        let r = EnvironmentDetector.fromProfile(try fixture("ios-no-push.mobileprovision"), platform: .ios)
        XCTAssertNil(r.environment)
        XCTAssertTrue(r.warning?.contains("Push Notifications") ?? false, r.warning ?? "no warning")
    }

    func testNoProfileOnMacIsProductionWithWarning() {
        for platform in [Platform.macos, .maccatalyst] {
            let r = EnvironmentDetector.fromProfile(nil, platform: platform)
            XCTAssertEqual(r.environment, .production)
            XCTAssertNotNil(r.warning)
        }
    }

    func testMacProfilesUseTheMacEntitlementKey() throws {
        let data = try fixture("macos-development.provisionprofile")
        XCTAssertEqual(EnvironmentDetector.fromProfile(data, platform: .macos).environment, .sandbox)
        XCTAssertEqual(EnvironmentDetector.fromProfile(data, platform: .maccatalyst).environment, .sandbox)
        // The iOS key is not looked for on the Mac, and vice versa.
        XCTAssertNil(EnvironmentDetector.fromProfile(data, platform: .ios).environment)
    }

    func testGarbageIsNotAProfile() {
        XCTAssertNil(EnvironmentDetector.parseProfile(Data("not a profile".utf8)))
    }
}
