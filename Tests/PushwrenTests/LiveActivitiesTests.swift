import Foundation
import os
import XCTest
@testable import Pushwren

/// An activity the test drives by hand, standing in for ActivityKit's `Activity`.
final class FakeActivity: LiveActivityHandle, @unchecked Sendable {
    let id: String
    let attributesType: String
    let pushwrenKey: String?
    private let over: OSAllocatedUnfairLock<Bool>
    private let tokens = AsyncStream.makeStream(of: Data.self)
    private let ends = AsyncStream.makeStream(of: Void.self)

    init(id: String, attributesType: String = "OrderAttributes", pushwrenKey: String? = nil, ended: Bool = false) {
        self.id = id
        self.attributesType = attributesType
        self.pushwrenKey = pushwrenKey
        over = OSAllocatedUnfairLock(initialState: ended)
    }

    var isOver: Bool { over.withLock { $0 } }
    func pushTokens(_ body: @Sendable (Data) async -> Void) async {
        for await token in tokens.stream { await body(token) }
    }
    func waitUntilOver() async {
        for await _ in ends.stream { return }
    }

    /// Apple issues (or rotates) the activity's update token.
    func issue(_ token: Data) { tokens.continuation.yield(token) }
    /// The activity ends on the device.
    func end() {
        over.withLock { $0 = true }
        ends.continuation.yield(())
    }
}

/// An activity type with remote start, standing in for `Activity<A>`'s static sequences.
final class FakeActivityKind: LiveActivityKind, @unchecked Sendable {
    let attributesType: String
    private let startTokens = AsyncStream.makeStream(of: Data.self)
    private let started = AsyncStream.makeStream(of: (any LiveActivityHandle).self)

    init(attributesType: String = "OrderAttributes") { self.attributesType = attributesType }

    func pushToStartTokens(_ body: @Sendable (Data) async -> Void) async {
        for await token in startTokens.stream { await body(token) }
    }
    func activities(_ body: @Sendable (any LiveActivityHandle) async -> Void) async {
        for await activity in started.stream { await body(activity) }
    }

    func issueStartToken(_ token: Data) { startTokens.continuation.yield(token) }
    /// Apple starts an activity from a push (or the app had one running at launch).
    func start(_ activity: FakeActivity) { started.continuation.yield(activity) }
}

/// The reports a tracker hands to the queue, in order.
final class ReportRecorder: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<[ActivityReport]>(initialState: [])
    var reports: [ActivityReport] { state.withLock { $0 } }
    func record(_ report: ActivityReport) { state.withLock { $0.append(report) } }
}

private func token(_ byte: UInt8, count: Int = 32) -> Data { Data(repeating: byte, count: count) }
private func hex(_ byte: UInt8, count: Int = 32) -> String { String(repeating: String(format: "%02x", byte), count: count) }
private let deviceToken = String(repeating: "a", count: 64)

final class LiveActivitiesTests: XCTestCase {
    private var recorder: ReportRecorder!
    private var tracker: LiveActivityTracker!

    override func setUp() {
        recorder = ReportRecorder()
        let recorder = self.recorder!
        tracker = LiveActivityTracker(report: { recorder.record($0) })
    }

    /// Waits (up to a second) until the tracker has handed over `count` reports.
    private func reports(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async -> [ActivityReport] {
        for _ in 0..<200 where recorder.reports.count < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // A little longer, so a report that shouldn't come has the chance to show up.
        try? await Task.sleep(nanoseconds: 20_000_000)
        return recorder.reports
    }

    // MARK: Tracking an activity the app started

    func testATokenIsReportedOnceAndARotationReportsTheNewToken() async {
        let activity = FakeActivity(id: "act-1")
        await tracker.track(activity, key: "order-A1001")
        activity.issue(token(0x01))
        activity.issue(token(0x01)) // ActivityKit's current token, then the same one from the stream
        var got = await reports(1)
        XCTAssertEqual(got, [.token(key: "order-A1001", token: hex(0x01), attributesType: "OrderAttributes")])
        // Apple rotates the token mid-activity (Review Focus 1): the new one is reported under the same key.
        activity.issue(token(0x02))
        got = await reports(2)
        XCTAssertEqual(got.last, .token(key: "order-A1001", token: hex(0x02), attributesType: "OrderAttributes"))
        XCTAssertEqual(got.count, 2)
    }

    func testAnActivityEndingReportsTheEndAndNothingAfterIt() async {
        let activity = FakeActivity(id: "act-1")
        await tracker.track(activity, key: "order-A1001")
        activity.issue(token(0x01))
        _ = await reports(1)
        activity.end()
        _ = await reports(2)
        activity.issue(token(0x03)) // too late: the activity is over
        let got = await reports(3)
        XCTAssertEqual(got, [
            .token(key: "order-A1001", token: hex(0x01), attributesType: "OrderAttributes"),
            .ended(key: "order-A1001"),
        ])
    }

    func testAnActivityAlreadyOverWhenTrackedReportsOnlyItsEnd() async {
        let activity = FakeActivity(id: "act-1", ended: true)
        await tracker.track(activity, key: "order-A1001")
        activity.issue(token(0x01))
        let got = await reports(1)
        XCTAssertEqual(got, [.ended(key: "order-A1001")])
    }

    func testTrackingTheSameActivityTwiceTracksItOnce() async {
        let activity = FakeActivity(id: "act-1")
        await tracker.track(activity, key: "order-A1001")
        await tracker.track(activity, key: "order-other")
        activity.issue(token(0x01))
        let got = await reports(1)
        XCTAssertEqual(got, [.token(key: "order-A1001", token: hex(0x01), attributesType: "OrderAttributes")])
    }

    func testAnInvalidKeyIsNotTracked() async {
        for key in ["", "has space", String(repeating: "k", count: 65), "..", "."] {
            let activity = FakeActivity(id: "act-\(key)")
            await tracker.track(activity, key: key)
            activity.issue(token(0x01))
        }
        let got = await reports(0)
        XCTAssertEqual(got, [])
    }

    func testATokenOfTheWrongLengthIsNotReported() async {
        let activity = FakeActivity(id: "act-1")
        await tracker.track(activity, key: "order-A1001")
        activity.issue(token(0x01, count: 8))
        activity.issue(token(0x02))
        let got = await reports(1)
        XCTAssertEqual(got, [.token(key: "order-A1001", token: hex(0x02), attributesType: "OrderAttributes")])
    }

    func testWhenOneOfTwoActivitiesUnderAKeyEndsTheOtherKeepsTheKey() async {
        let first = FakeActivity(id: "act-1")
        let second = FakeActivity(id: "act-2")
        await tracker.track(first, key: "order-A1001")
        first.issue(token(0x01))
        _ = await reports(1)
        await tracker.track(second, key: "order-A1001")
        second.issue(token(0x02))
        _ = await reports(2)
        first.end()
        let got = await reports(3)
        // Not an end: the device still has a live activity under the key, so its token goes back.
        XCTAssertEqual(got.last, .token(key: "order-A1001", token: hex(0x02), attributesType: "OrderAttributes"))
        XCTAssertEqual(got.count, 3)
    }

    // MARK: Remote start

    func testRemoteStartReportsTheStartTokenAndItsRotation() async {
        let kind = FakeActivityKind()
        await tracker.enableRemoteStart(kind)
        await tracker.enableRemoteStart(kind) // a second call changes nothing
        kind.issueStartToken(token(0x0a))
        kind.issueStartToken(token(0x0a))
        _ = await reports(1)
        kind.issueStartToken(token(0x0b))
        let got = await reports(2)
        XCTAssertEqual(got, [
            .startToken(attributesType: "OrderAttributes", token: hex(0x0a)),
            .startToken(attributesType: "OrderAttributes", token: hex(0x0b)),
        ])
    }

    func testTheLongerTokensIOS27IssuesAreReported() async {
        // iOS 27 issues 128-byte push-to-start tokens; the server takes up to 256 bytes.
        let kind = FakeActivityKind()
        await tracker.enableRemoteStart(kind)
        kind.issueStartToken(token(0x0c, count: 128))
        let activity = FakeActivity(id: "act-1")
        await tracker.track(activity, key: "order-A1001")
        activity.issue(token(0x0d, count: 257))
        activity.issue(token(0x0e, count: 256))
        let got = await reports(2)
        XCTAssertEqual(got, [
            .startToken(attributesType: "OrderAttributes", token: hex(0x0c, count: 128)),
            .token(key: "order-A1001", token: hex(0x0e, count: 256), attributesType: "OrderAttributes"),
        ])
    }

    func testARemoteStartedActivityIsTrackedUnderItsPushwrenKey() async {
        let kind = FakeActivityKind()
        await tracker.enableRemoteStart(kind)
        let activity = FakeActivity(id: "act-remote", pushwrenKey: "order-A1002")
        kind.start(activity)
        // iOS 18 issues an update token for an activity started from a push (input-push-token: 1).
        activity.issue(token(0x05))
        _ = await reports(1)
        activity.end()
        let got = await reports(2)
        XCTAssertEqual(got, [
            .token(key: "order-A1002", token: hex(0x05), attributesType: "OrderAttributes"),
            .ended(key: "order-A1002"),
        ])
    }

    func testARemoteStartedActivityWithoutAnUpdateTokenStillReportsItsEnd() async {
        // Whether iOS 17.2–17.x issues an update token after a push-to-start is unverified (R9).
        let kind = FakeActivityKind()
        await tracker.enableRemoteStart(kind)
        let activity = FakeActivity(id: "act-remote", pushwrenKey: "order-A1003")
        kind.start(activity)
        try? await Task.sleep(nanoseconds: 20_000_000)
        activity.end()
        let got = await reports(1)
        XCTAssertEqual(got, [.ended(key: "order-A1003")])
    }

    func testAnActivityWithAnInvalidPushwrenKeyIsNotTracked() async {
        let kind = FakeActivityKind()
        await tracker.enableRemoteStart(kind)
        let activity = FakeActivity(id: "act-remote", pushwrenKey: "not a key")
        kind.start(activity)
        activity.issue(token(0x05))
        let got = await reports(0)
        XCTAssertEqual(got, [])
    }

    func testReportAgainRepeatsEveryKnownToken() async {
        let kind = FakeActivityKind()
        await tracker.enableRemoteStart(kind)
        kind.issueStartToken(token(0x0a))
        let activity = FakeActivity(id: "act-1")
        await tracker.track(activity, key: "order-A1001")
        activity.issue(token(0x01))
        _ = await reports(2)
        // The server made a new record for this device: it has none of the tokens.
        await tracker.reportAgain()
        let got = await reports(4)
        XCTAssertEqual(Set(got.suffix(2).map { "\($0)" }), Set([
            ActivityReport.startToken(attributesType: "OrderAttributes", token: hex(0x0a)),
            .token(key: "order-A1001", token: hex(0x01), attributesType: "OrderAttributes"),
        ].map { "\($0)" }))
    }

    // MARK: The attributes type

    struct OrderAttributes {}
    enum Outer { struct Nested {} }

    func testTheAttributesTypeIsTheSwiftTypeName() {
        // What Apple matches as `attributes-type` on a remote start.
        XCTAssertEqual(LiveActivityTracker.attributesType(of: OrderAttributes.self), "OrderAttributes")
        XCTAssertEqual(LiveActivityTracker.attributesType(of: Outer.Nested.self), "Nested")
    }

    func testTheLiveActivityAPIIsOnlyOnIOS() {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        _ = Pushwren.liveActivities
        #else
        // macOS and Mac Catalyst have no Live Activities: only the tracker's platform-free core
        // compiles here, and nothing reaches it.
        XCTAssertTrue(true)
        #endif
    }
}

// MARK: The queue

final class ActivityReportQueueTests: XCTestCase {
    private let a = ActivityReport.token(key: "k1", token: hex(0x01), attributesType: "OrderAttributes")

    func testANewerTokenForAKeyReplacesAnUnsentOne() {
        var p = PendingChanges()
        p.report(.token(key: "k1", token: hex(0x01), attributesType: "OrderAttributes"))
        p.report(.token(key: "k2", token: hex(0x02), attributesType: "OrderAttributes"))
        p.report(.token(key: "k1", token: hex(0x03), attributesType: "OrderAttributes"))
        XCTAssertEqual(p.activities, [
            .token(key: "k2", token: hex(0x02), attributesType: "OrderAttributes"),
            .token(key: "k1", token: hex(0x03), attributesType: "OrderAttributes"),
        ])
    }

    func testAnEndComesAfterEveryTokenForItsKey() {
        var p = PendingChanges()
        p.report(a)
        p.report(.token(key: "k2", token: hex(0x02), attributesType: "OrderAttributes"))
        p.report(.ended(key: "k1"))
        p.report(.ended(key: "k1"))
        // The unsent token of an activity that has ended is moot: only the end goes.
        XCTAssertEqual(p.activities, [.token(key: "k2", token: hex(0x02), attributesType: "OrderAttributes"), .ended(key: "k1")])
        // A new activity under the key after the end: its token goes after the end.
        p.report(.token(key: "k1", token: hex(0x04), attributesType: "OrderAttributes"))
        XCTAssertEqual(p.activities.last, .token(key: "k1", token: hex(0x04), attributesType: "OrderAttributes"))
        XCTAssertEqual(p.activities.firstIndex(of: .ended(key: "k1")), 1)
    }

    func testANewerStartTokenForATypeReplacesAnUnsentOne() {
        var p = PendingChanges()
        p.report(.startToken(attributesType: "OrderAttributes", token: hex(0x01)))
        p.report(.startToken(attributesType: "GameAttributes", token: hex(0x02)))
        p.report(.startToken(attributesType: "OrderAttributes", token: hex(0x03)))
        XCTAssertEqual(p.activities, [
            .startToken(attributesType: "GameAttributes", token: hex(0x02)),
            .startToken(attributesType: "OrderAttributes", token: hex(0x03)),
        ])
    }

    func testClearForgetsOnlyWhatWasSent() {
        var p = PendingChanges()
        p.report(a)
        let sent = p.activities[0]
        p.report(.token(key: "k1", token: hex(0x09), attributesType: "OrderAttributes")) // rotated while in flight
        p.clear(sent: sent)
        XCTAssertEqual(p.activities, [.token(key: "k1", token: hex(0x09), attributesType: "OrderAttributes")])
    }

    func testTheQueueIsCapped() {
        var p = PendingChanges()
        for i in 0..<(PendingChanges.maxActivityReports + 5) { p.report(.ended(key: "k\(i)")) }
        XCTAssertEqual(p.activities.count, PendingChanges.maxActivityReports)
        XCTAssertEqual(p.activities.first, .ended(key: "k5"), "the oldest are dropped")
    }

    func testStateSavedBy030DecodesWithNoReports() throws {
        let saved = #"{"add":["pro"],"remove":[]}"#
        let p = try JSONDecoder().decode(PendingChanges.self, from: Data(saved.utf8))
        XCTAssertEqual(p.add, ["pro"])
        XCTAssertEqual(p.activities, [])
    }

    func testReportsRoundTripThroughJSON() throws {
        var p = PendingChanges()
        p.report(a)
        p.report(.ended(key: "k2"))
        p.report(.startToken(attributesType: "OrderAttributes", token: hex(0x03)))
        let decoded = try JSONDecoder().decode(PendingChanges.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p)
    }
}

// MARK: Sending the reports

final class ActivityReportSyncTests: XCTestCase {
    private let key = AppKey("pk_dev_AbCdEfGhIjKlMnOpQrStUvWxYz012345")!
    private let base = DeviceState(platform: .ios, bundleId: "com.pushwren.sample", sdkVersion: "0.4.0")
    private var identity: MemoryIdentityStore!
    private var store: MemoryStateStore!
    private var sleeper: SleepRecorder!

    override func setUp() {
        identity = MemoryIdentityStore()
        store = MemoryStateStore()
        sleeper = SleepRecorder()
        StubURLProtocol.answer { r in
            r.request.httpMethod == "PUT" && r.request.url?.path.hasPrefix("/v1/devices/") == true && r.request.url?.pathComponents.count == 4
                ? .json(201, ["deviceId": "x", "deviceSecret": "secret-1"])
                : .response(status: 204)
        }
    }

    private func engine(debounce: TimeInterval = 0, realSleep: Bool = false, onNewRecord: @escaping @Sendable () -> Void = {}) -> SyncEngine {
        let sleeper = self.sleeper!
        let sleep: @Sendable (TimeInterval) async -> Void
        if realSleep {
            sleep = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        } else {
            sleep = { s in await sleeper.sleep(s) }
        }
        return SyncEngine(
            client: APIClient(key: key, session: StubURLProtocol.session()),
            identity: identity,
            store: store,
            initial: base,
            sleep: sleep,
            debounce: debounce,
            onNewRecord: onNewRecord
        )
    }

    private var requests: [String] {
        StubURLProtocol.recorded.map { "\($0.request.httpMethod ?? "?") \($0.request.url?.absoluteString ?? "?")" }
    }

    private func json(_ i: Int) -> [String: Any] {
        let recorded = StubURLProtocol.recorded
        guard i < recorded.count else { return [:] }
        return (try? JSONSerialization.jsonObject(with: recorded[i].body) as? [String: Any]) ?? [:]
    }

    private func registered() async -> SyncEngine {
        let e = engine()
        await e.update { $0.token = deviceToken; $0.environment = .sandbox }
        await e.settle()
        return e
    }

    func testReportsGoOutAfterRegistrationWithTheDeviceSecret() async throws {
        let e = engine()
        // Reported before the device has registered: they wait for its secret.
        await e.reportActivity(.token(key: "order:A1001", token: hex(0x01), attributesType: "OrderAttributes"))
        await e.reportActivity(.startToken(attributesType: "OrderAttributes", token: hex(0x0a)))
        await e.reportActivity(.ended(key: "order-A1000"))
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0, "nothing goes before the device has a token")
        await e.update { $0.token = deviceToken; $0.environment = .sandbox }
        await e.settle()
        let id = try XCTUnwrap(identity.load()?.deviceID)
        XCTAssertEqual(requests, [
            "PUT https://api.dev.pushwren.com/v1/devices/\(id)",
            "PUT https://api.dev.pushwren.com/v1/devices/\(id)/live-activities/order%3AA1001",
            "PUT https://api.dev.pushwren.com/v1/devices/\(id)/start-tokens/OrderAttributes",
            "DELETE https://api.dev.pushwren.com/v1/devices/\(id)/live-activities/order-A1000",
        ])
        XCTAssertEqual(json(1) as NSDictionary, ["token": hex(0x01), "attributesType": "OrderAttributes"])
        XCTAssertEqual(json(2) as NSDictionary, ["token": hex(0x0a)])
        XCTAssertTrue(StubURLProtocol.recorded[3].body.isEmpty)
        for r in StubURLProtocol.recorded.dropFirst() {
            XCTAssertEqual(r.request.value(forHTTPHeaderField: "X-Device-Secret"), "secret-1")
            XCTAssertEqual(r.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key.raw)")
        }
        XCTAssertEqual(store.load()?.pending.activities, [], "nothing left pending")
    }

    func testAnAttributesTypeIsPercentEncodedInThePath() async throws {
        let e = await registered()
        await e.reportActivity(.startToken(attributesType: "Box<Order Attributes>", token: hex(0x0a)))
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.last?.request.url?.absoluteString.hasSuffix("/start-tokens/Box%3COrder%20Attributes%3E"), true, "\(requests)")
    }

    func testAConflictIsDroppedOnceAndNotRetried() async {
        let e = await registered()
        StubURLProtocol.answer { _ in .json(409, ["error": ["code": "conflict", "message": "order-1 is a broadcast key; a device can't register a token under it"]]) }
        await e.reportActivity(.token(key: "order-1", token: hex(0x01), attributesType: "OrderAttributes"))
        await e.settle()
        await e.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.filter { $0.request.url?.path.contains("live-activities") == true }.count, 1)
        XCTAssertEqual(store.load()?.pending.activities, [])
        let rejected = await e.lastRejected
        XCTAssertEqual(rejected?.error, .rejected(code: "conflict", message: "order-1 is a broadcast key; a device can't register a token under it"))
        XCTAssertTrue(sleeper.waits.allSatisfy { $0 == 0 }, "no backoff for a refusal: \(sleeper.waits)")
    }

    func testATransientFailureRetriesTheReport() async {
        let e = await registered()
        let count = OSAllocatedUnfairLock(initialState: 0)
        StubURLProtocol.answer { _ in
            count.withLock { n -> StubURLProtocol.Answer in
                n += 1
                return n == 1 ? .json(503, [:]) : .response(status: 204)
            }
        }
        await e.reportActivity(.ended(key: "order-1"))
        await e.settle()
        XCTAssertEqual(count.withLock { $0 }, 2)
        XCTAssertEqual(store.load()?.pending.activities, [])
        XCTAssertEqual(sleeper.waits.filter { $0 > 0 }.count, 1)
    }

    func testATryAgainFromTheServerRetriesTheTokenReportAfterABackoff() async {
        // The server answers 503 try_again while an end is waiting to be sent, or when the key changed
        // under the request: the token goes again, after a wait, and isn't dropped.
        let e = await registered()
        let count = OSAllocatedUnfairLock(initialState: 0)
        StubURLProtocol.answer { _ in
            count.withLock { n -> StubURLProtocol.Answer in
                n += 1
                return n == 1 ? .json(503, ["error": ["code": "try_again", "message": "order-1 is ending; try again in a moment"]]) : .response(status: 204)
            }
        }
        await e.reportActivity(.token(key: "order-1", token: hex(0x01), attributesType: "OrderAttributes"))
        await e.settle()
        XCTAssertEqual(count.withLock { $0 }, 2)
        XCTAssertEqual(StubURLProtocol.recorded.filter { $0.request.url?.path.hasSuffix("/live-activities/order-1") == true }.count, 2)
        XCTAssertEqual(store.load()?.pending.activities, [])
        XCTAssertEqual(sleeper.waits.filter { $0 > 0 }.count, 1, "one backoff before the retry: \(sleeper.waits)")
        let rejected = await e.lastRejected
        XCTAssertNil(rejected)
    }

    func testAServerStartedKeyForOtherDevicesIsDroppedNotRetried() async {
        let e = await registered()
        StubURLProtocol.answer { _ in .json(409, ["error": ["code": "conflict", "message": "order-A1002: this Live Activity was started by the server for other devices"]]) }
        await e.reportActivity(.token(key: "order-A1002", token: hex(0x01), attributesType: "OrderAttributes"))
        await e.settle()
        await e.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.filter { $0.request.url?.path.contains("live-activities") == true }.count, 1)
        XCTAssertEqual(store.load()?.pending.activities, [])
        XCTAssertTrue(sleeper.waits.allSatisfy { $0 == 0 }, "no backoff for a refusal: \(sleeper.waits)")
    }

    func testReportsSurviveARelaunch() async {
        _ = await registered()
        StubURLProtocol.answer { _ in .response(status: 204) }
        // The app is gone before the report goes out.
        let first = engine(debounce: 60, realSleep: true)
        await first.reportActivity(.token(key: "order-1", token: hex(0x01), attributesType: "OrderAttributes"))
        await first.stop()
        let before = StubURLProtocol.recorded.count
        XCTAssertEqual(before, 0)
        // Next launch, with nothing called again.
        let second = engine()
        await second.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        XCTAssertEqual(StubURLProtocol.recorded.first?.request.url?.path.hasSuffix("/live-activities/order-1"), true)
        XCTAssertEqual(store.load()?.pending.activities, [])
    }

    func testANewRecordKeepsQueuedReportsAndAsksForTheKnownOnesAgain() async {
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let e = engine(onNewRecord: { asked.withLock { $0 += 1 } })
        await e.update { $0.token = deviceToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(asked.withLock { $0 }, 1, "the first registration is a new record")
        // The server lost the record: 403 starts over as a new device, which has none of the tokens.
        let count = OSAllocatedUnfairLock(initialState: 0)
        StubURLProtocol.answer { _ in
            count.withLock { n -> StubURLProtocol.Answer in
                n += 1
                switch n {
                case 1: return .json(403, ["error": ["code": "forbidden", "message": "x"]])
                case 2: return .json(201, ["deviceId": "x", "deviceSecret": "fresh"])
                default: return .response(status: 204)
                }
            }
        }
        await e.reportActivity(.ended(key: "order-1"))
        await e.update { $0.appVersion = "2.0" }
        await e.settle()
        XCTAssertEqual(asked.withLock { $0 }, 2)
        XCTAssertEqual(StubURLProtocol.recorded.last?.request.httpMethod, "DELETE", "the queued report survived the new record")
        XCTAssertEqual(StubURLProtocol.recorded.last?.request.value(forHTTPHeaderField: "X-Device-Secret"), "fresh")
    }

    // MARK: Channel lookup

    func testChannelLookupSendsTheDeviceIDAndReturnsTheChannel() async throws {
        let e = await registered()
        StubURLProtocol.answer { _ in .json(200, ["channelId": "dHN0LXNyY2gtY2hubA=="]) }
        let channel = try await e.channel(for: "game:4521")
        XCTAssertEqual(channel, "dHN0LXNyY2gtY2hubA==")
        let id = try XCTUnwrap(identity.load()?.deviceID)
        let sent = try XCTUnwrap(StubURLProtocol.recorded.last)
        XCTAssertEqual(sent.request.httpMethod, "GET")
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.dev.pushwren.com/v1/live-activities/game%3A4521/channel?deviceId=\(id)")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-Device-Secret"), "secret-1")
    }

    func testChannelLookupWithoutAChannelOrARegistration() async {
        do {
            _ = try await engine().channel(for: "game-4521")
            XCTFail("expected notRegistered")
        } catch {
            XCTAssertEqual(error, .notRegistered)
        }
        let e = await registered()
        StubURLProtocol.answer { _ in .json(404, ["error": ["code": "not_found", "message": "No broadcast channel for game-4521"]]) }
        do {
            _ = try await e.channel(for: "game-4521")
            XCTFail("expected noChannel")
        } catch {
            XCTAssertEqual(error, .noChannel)
        }
        StubURLProtocol.answer { _ in .failure(.notConnectedToInternet) }
        do {
            _ = try await e.channel(for: "game-4521")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error, .requestFailed("transient"))
        }
    }
}
