import Foundation
import os
import XCTest
@testable import Pushwren

final class OpenTrackerTests: XCTestCase {
    private let key = AppKey("pk_dev_AbCdEfGhIjKlMnOpQrStUvWxYz012345")!
    private let base = DeviceState(platform: .ios, bundleId: "com.pushwren.sample", sdkVersion: "0.2.0")
    private let ntf = "ntf_01JD3QF1V6N8R2Y4P7S9T0AKME"
    private let token = String(repeating: "a", count: 64)
    private var identity: MemoryIdentityStore!
    private var store: MemoryStateStore!

    override func setUp() {
        identity = MemoryIdentityStore()
        store = MemoryStateStore()
        StubURLProtocol.answer { r in
            r.request.httpMethod == "PUT" ? .json(201, ["deviceId": "x", "deviceSecret": "secret-1"]) : .json(204, [:])
        }
    }

    private func engine(debounce: TimeInterval = 0, realSleep: Bool = false) -> SyncEngine {
        SyncEngine(
            client: APIClient(key: key, session: StubURLProtocol.session()),
            identity: identity,
            store: store,
            initial: base,
            sleep: realSleep ? SyncEngine.sleep : { @Sendable _ in },
            debounce: debounce
        )
    }

    private var events: [[String: Any]] {
        StubURLProtocol.recorded
            .filter { $0.request.url?.path == "/v1/events" }
            .compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
    }

    func testATapWithHPostsOneOpenedEvent() async {
        let e = engine()
        await e.update { [token] in $0.token = token; $0.environment = .sandbox }
        await e.settle()
        await e.recordOpen(ntf)
        await e.settle()
        let deviceID = (try? identity.load())??.deviceID
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "opened")
        XCTAssertEqual(events.first?["notificationId"] as? String, ntf)
        XCTAssertEqual(events.first?["deviceId"] as? String, deviceID)
        let sent = StubURLProtocol.recorded.last
        XCTAssertEqual(sent?.request.httpMethod, "POST")
        XCTAssertEqual(sent?.request.value(forHTTPHeaderField: "X-Device-Secret"), "secret-1")
        XCTAssertEqual(store.load()?.opens, [])
    }

    func testAnOpenBeforeRegistrationWaitsForTheSecret() async {
        let e = engine()
        await e.recordOpen(ntf)
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
        await e.update { [token] in $0.token = token; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.map { $0.request.httpMethod }, ["PUT", "POST"])
    }

    func testAQueuedOpenSurvivesRelaunchAndIsSentOnce() async {
        let first = engine()
        await first.update { [token] in $0.token = token; $0.environment = .sandbox }
        await first.settle()
        let launching = engine(debounce: 60, realSleep: true)
        await launching.recordOpen(ntf)
        await launching.stop()
        XCTAssertEqual(events.count, 0)
        let next = engine()
        await next.syncIfNeeded()
        await next.syncIfNeeded()
        XCTAssertEqual(events.count, 1)
    }

    func test404DropsTheEvent() async {
        let e = engine()
        await e.update { [token] in $0.token = token; $0.environment = .sandbox }
        await e.settle()
        StubURLProtocol.answer { _ in .json(404, ["error": ["code": "not_found", "message": "x"]]) }
        await e.recordOpen(ntf)
        await e.settle()
        await e.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.count, 1, "sent once, then dropped")
        XCTAssertEqual(store.load()?.opens, [])
    }

    func testAnOpenWithoutHYieldsButPostsNothing() {
        let foreign = OpenedNotification(userInfo: ["aps": ["alert": "hi"], "orderId": "A1"], actionIdentifier: "tap")
        XCTAssertNil(foreign.notificationID)
        XCTAssertEqual(foreign.data["orderId"] as? String, "A1")
        let malformed = OpenedNotification(userInfo: ["_h": "not-a-notification-id"], actionIdentifier: "tap")
        XCTAssertNil(malformed.notificationID)
    }

    func testDataLeavesOutApsAndH() {
        let open = OpenedNotification(userInfo: ["aps": ["alert": "hi"], "_h": ntf, "orderId": "A1", "n": 3], actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier")
        XCTAssertEqual(open.notificationID, ntf)
        XCTAssertEqual(Set(open.data.keys), ["orderId", "n"])
        XCTAssertEqual(open.data["n"] as? Int, 3)
        XCTAssertEqual(open.actionIdentifier, "com.apple.UNNotificationDefaultActionIdentifier")
    }

    func testDataLeavesOutTheImageAndReceiptKeys() {
        let open = OpenedNotification(
            userInfo: ["aps": ["alert": "hi"], "_h": ntf, "_i": "https://example.com/a.jpg", "_r": "rc_1", "orderId": "A1"],
            actionIdentifier: "tap"
        )
        XCTAssertEqual(Set(open.data.keys), ["orderId"])
        XCTAssertTrue(open.receiptRequested)
        XCTAssertFalse(OpenedNotification(userInfo: ["_h": ntf, "_i": "https://example.com/a.jpg"], actionIdentifier: "tap").receiptRequested)
    }

    func testAnOpenOfAPushThatAskedForAReceiptSaysSo() async {
        let e = engine()
        await e.update { [token] in $0.token = token; $0.environment = .sandbox }
        await e.settle()
        let other = "ntf_01JD3QF1V6N8R2Y4P7S9T0AKMF"
        await e.recordOpen(ntf, receiptRequested: true)
        await e.settle()
        await e.recordOpen(other, receiptRequested: false)
        await e.settle()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?["notificationId"] as? String, ntf)
        XCTAssertEqual(events.first?["receiptRequested"] as? Bool, true)
        XCTAssertEqual(events.last?["notificationId"] as? String, other)
        XCTAssertNil(events.last?["receiptRequested"], "left out when the push didn't ask")
        XCTAssertEqual(store.load()?.opensWithReceipt, [])
    }

    func testAQueuedOpenKeepsItsReceiptFlagAcrossARelaunch() async {
        let first = engine()
        await first.update { [token] in $0.token = token; $0.environment = .sandbox }
        await first.settle()
        let launching = engine(debounce: 60, realSleep: true)
        await launching.recordOpen(ntf, receiptRequested: true)
        await launching.stop()
        XCTAssertEqual(events.count, 0)
        let next = engine()
        await next.syncIfNeeded()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["receiptRequested"] as? Bool, true)
    }

    func testAnOpenBeforeAnySubscriberReachesTheFirstSubscriber() async {
        let b = OpenBroadcaster()
        b.yield(OpenedNotification(userInfo: ["_h": ntf], actionIdentifier: "tap"))
        var it = b.subscribe().makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first?.notificationID, ntf)
    }

    func testTwoSubscribersBothSeeAnOpen() async {
        let b = OpenBroadcaster()
        var a = b.subscribe().makeAsyncIterator()
        var c = b.subscribe().makeAsyncIterator()
        b.yield(OpenedNotification(userInfo: ["_h": ntf], actionIdentifier: "tap"))
        let fromA = await a.next()
        let fromC = await c.next()
        XCTAssertEqual(fromA?.notificationID, ntf)
        XCTAssertEqual(fromC?.notificationID, ntf)
    }

    func testTheBufferHoldsAtMostTenOpens() async {
        let b = OpenBroadcaster()
        for i in 0..<12 { b.yield(OpenedNotification(userInfo: ["n": i], actionIdentifier: "tap")) }
        var it = b.subscribe().makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first?.data["n"] as? Int, 2, "the oldest two were dropped")
    }

    func testARejectedPatchIsDroppedAndDoesNotBlockOpens() async {
        let e = engine()
        await e.update { [token] in $0.token = token; $0.environment = .sandbox }
        await e.settle()
        StubURLProtocol.answer { r in
            r.request.httpMethod == "PATCH"
                ? .json(400, ["error": ["code": "invalid_request", "message": "tags: a device may have at most 50 tags"]])
                : .json(204, [:])
        }
        await e.addTags(["one-too-many"])
        await e.recordOpen(ntf)
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.map { $0.request.httpMethod }, ["PATCH", "POST"])
        XCTAssertNil(store.load()?.pending.patch(), "the rejected change is dropped, not retried forever")
        XCTAssertEqual(store.load()?.opens, [])
        await e.setUser("u_2", signature: nil)
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.last?.request.httpMethod, "PATCH", "later changes still go out")
    }
}
