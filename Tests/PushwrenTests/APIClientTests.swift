import XCTest
@testable import Pushwren

final class APIClientTests: XCTestCase {
    private let key = AppKey("pk_dev_AbCdEfGhIjKlMnOpQrStUvWxYz012345")!
    private let deviceID = "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA"
    private let payload = DevicePayload(
        token: String(repeating: "a", count: 64),
        environment: .sandbox,
        platform: .ios,
        bundleId: "com.pushwren.sample",
        authorizationStatus: .authorized,
        userId: "u_1",
        tags: ["pro", "beta"],
        sdkVersion: "0.1.0"
    )

    private func client() -> APIClient { APIClient(key: key, session: StubURLProtocol.session()) }

    func testPutSendsBearerKeySecretHeaderAndJSON() async throws {
        StubURLProtocol.answer { _ in .json(200, ["deviceId": "x"]) }
        let secret = try await client().putDevice(deviceID, payload, secret: "s3cret")
        XCTAssertNil(secret)
        let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(sent.request.httpMethod, "PUT")
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.dev.pushwren.com/v1/devices/\(deviceID)")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key.raw)")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-Device-Secret"), "s3cret")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "User-Agent"), "pushwren-swift/\(SDK.version)")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(json["token"] as? String, payload.token)
        XCTAssertEqual(json["environment"] as? String, "sandbox")
        XCTAssertEqual(json["tags"] as? [String], ["beta", "pro"], "tags are sent sorted")
        XCTAssertNil(json["locale"], "absent fields are left out, not sent as null")
    }

    func testFirstRegistrationSendsNoSecretAndReturnsTheNewOne() async throws {
        StubURLProtocol.answer { _ in .json(201, ["deviceId": "x", "deviceSecret": "new-secret"]) }
        let secret = try await client().putDevice(deviceID, payload, secret: nil)
        XCTAssertEqual(secret, "new-secret")
        XCTAssertNil(StubURLProtocol.recorded.first?.request.value(forHTTPHeaderField: "X-Device-Secret"))
    }

    func testStatusMapping() async {
        let cases: [(StubURLProtocol.Answer, APIError)] = [
            (.json(400, ["error": ["code": "bundle_mismatch", "message": "wrong app"]]), .rejected(code: "bundle_mismatch", message: "wrong app")),
            (.json(401, ["error": ["code": "invalid_api_key", "message": "x"]]), .invalidKey),
            (.json(403, ["error": ["code": "forbidden", "message": "x"]]), .forbidden),
            (.json(429, ["error": ["code": "rate_limited", "message": "x"]], headers: ["Retry-After": "7"]), .retryAfter(7)),
            (.json(503, [:]), .transient),
            (.failure(.timedOut), .transient),
            (.failure(.notConnectedToInternet), .transient),
        ]
        for (answer, expected) in cases {
            StubURLProtocol.answer { _ in answer }
            do {
                _ = try await client().putDevice(deviceID, payload, secret: nil)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testDeleteSendsTheSecretAndTreatsAMissingDeviceAsDone() async throws {
        for status in [204, 404] {
            StubURLProtocol.answer { _ in .response(status: status) }
            try await client().deleteDevice(deviceID, secret: "s3cret")
            let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
            XCTAssertEqual(sent.request.httpMethod, "DELETE")
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-Device-Secret"), "s3cret")
        }
    }

    func testRetryPolicyBackoffIsBoundedAndJittered() {
        for attempt in 0..<30 {
            let base = min(300, pow(2, Double(attempt)))
            let low = RetryPolicy.delay(attempt: attempt, error: .transient, jitter: 0.5)!
            let high = RetryPolicy.delay(attempt: attempt, error: .transient, jitter: 1.0)!
            XCTAssertEqual(low, base * 0.5, accuracy: 0.0001)
            XCTAssertEqual(high, base, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(high, 300)
        }
        let random = (0..<50).compactMap { _ in RetryPolicy.delay(attempt: 3, error: .transient) }
        XCTAssertTrue(random.allSatisfy { (4...8).contains($0) })
        XCTAssertGreaterThan(Set(random).count, 1, "jitter varies")
    }

    func testRetryPolicyHonorsRetryAfter() {
        XCTAssertEqual(RetryPolicy.delay(attempt: 0, error: .retryAfter(7)), 7)
        XCTAssertEqual(RetryPolicy.delay(attempt: 9, error: .retryAfter(42)), 42)
    }

    func testRetryPolicyDoesNotRetryRejections() {
        for error in [APIError.forbidden, .invalidKey, .rejected(code: "invalid_request", message: "x")] {
            XCTAssertNil(RetryPolicy.delay(attempt: 0, error: error))
        }
    }

    func testMemoryIdentityStoreRoundTrips() {
        let store = MemoryIdentityStore()
        XCTAssertNil(store.load())
        store.save(deviceID: deviceID, secret: nil)
        XCTAssertEqual(store.load()?.deviceID, deviceID)
        XCTAssertNil(store.load()?.secret)
        store.save(deviceID: deviceID, secret: "s")
        XCTAssertEqual(store.load()?.secret, "s")
        store.reset()
        XCTAssertNil(store.load())
    }
}
