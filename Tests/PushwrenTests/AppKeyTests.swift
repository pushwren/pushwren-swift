import XCTest
@testable import Pushwren

final class AppKeyTests: XCTestCase {
    private let body = "AbCdEfGhIjKlMnOpQrStUvWxYz012345"

    func testDevKeyUsesDevHost() {
        XCTAssertEqual(AppKey("pk_dev_\(body)")?.apiBaseURL, URL(string: "https://api.dev.pushwren.com")!)
    }

    func testLiveKeyUsesProdHost() {
        XCTAssertEqual(AppKey("pk_live_\(body)")?.apiBaseURL, URL(string: "https://api.pushwren.com")!)
    }

    func testSecretAndMalformedKeysAreRejected() {
        for bad in ["sk_dev_\(body)", "sk_live_\(body)", "pk_test_\(body)", "pk_dev_short", "pk_dev_\(body)x", "", " pk_dev_\(body)"] {
            XCTAssertNil(AppKey(bad), bad)
        }
    }
}
