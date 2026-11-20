import Foundation
import os
import XCTest
@testable import Pushwren

/// A clock the test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 1_795_000_000)) { state = OSAllocatedUnfairLock(initialState: start) }
    var now: Date { state.withLock { $0 } }
    func advance(days: Double) { state.withLock { $0 = $0.addingTimeInterval(days * 86_400) } }
}

/// Records every wait instead of waiting.
final class SleepRecorder: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
    var waits: [TimeInterval] { state.withLock { $0 } }
    func sleep(_ seconds: TimeInterval) async { state.withLock { $0.append(seconds) } }
}

private let testToken = String(repeating: "a", count: 64)

/// A Keychain that can't be read, as before the first unlock after a reboot.
final class LockedIdentityStore: IdentityStore, @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var saves: Int { count.withLock { $0 } }
    func load() throws -> (deviceID: String, secret: String?)? { throw IdentityUnavailable(status: -25308) }
    func save(deviceID: String, secret: String?) { count.withLock { $0 += 1 } }
    func reset() {}
}

final class SyncEngineTests: XCTestCase {
    private let key = AppKey("pk_dev_AbCdEfGhIjKlMnOpQrStUvWxYz012345")!
    private let base = DeviceState(platform: .ios, bundleId: "com.pushwren.sample", sdkVersion: "0.1.0")

    private var clock: ManualClock!
    private var sleeper: SleepRecorder!
    private var identity: MemoryIdentityStore!
    private var store: MemoryStateStore!

    override func setUp() {
        clock = ManualClock()
        sleeper = SleepRecorder()
        identity = MemoryIdentityStore()
        store = MemoryStateStore()
        StubURLProtocol.answer { _ in .json(201, ["deviceId": "x", "deviceSecret": "secret-1"]) }
    }

    /// Answers each request in turn from `answers`, then repeats the last one.
    private func answer(_ answers: [StubURLProtocol.Answer]) {
        let count = OSAllocatedUnfairLock(initialState: 0)
        StubURLProtocol.answer { _ in
            let i = count.withLock { n -> Int in defer { n += 1 }; return n }
            return answers[min(i, answers.count - 1)]
        }
    }

    private func engine(debounce: TimeInterval = 0, realSleep: Bool = false, freshIdentity: Bool = false, identityStore: IdentityStore? = nil) -> SyncEngine {
        let clock = self.clock!
        let sleeper = self.sleeper!
        let sleep: @Sendable (TimeInterval) async -> Void
        if realSleep {
            sleep = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        } else {
            sleep = { s in await sleeper.sleep(s) }
        }
        return SyncEngine(
            client: APIClient(key: key, session: StubURLProtocol.session()),
            identity: identityStore ?? identity,
            store: store,
            initial: base,
            now: { clock.now },
            sleep: sleep,
            debounce: debounce,
            freshIdentity: freshIdentity
        )
    }

    private var sentBodies: [[String: Any]] {
        StubURLProtocol.recorded.compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
    }

    func testNothingIsSentBeforeATokenArrives() async {
        let e = engine()
        await e.update { $0.userId = "u_1" }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
    }

    func testUserIDAndTagsSetBeforeTheTokenGoOutWithTheFirstRegistration() async {
        let e = engine()
        await e.update { $0.userId = "u_1" }
        await e.update { $0.tags = ["pro"] }
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        XCTAssertEqual(sentBodies.first?["userId"] as? String, "u_1")
        XCTAssertEqual(sentBodies.first?["tags"] as? [String], ["pro"])
    }

    func testPendingChangeIsSentAfterRelaunch() async {
        // First launch: the change is saved, but the app is gone before it syncs.
        let first = engine(debounce: 60, realSleep: true)
        await first.update { $0.token = testToken; $0.environment = .sandbox; $0.userId = "u_1" }
        await first.stop()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
        // Next launch, with nothing called again.
        let second = engine()
        await second.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        XCTAssertEqual(sentBodies.first?["userId"] as? String, "u_1")
    }

    func testUnchangedStateIsNotResentWithinSevenDays() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        clock.advance(days: 6.9)
        await e.syncIfNeeded()
        await e.update { $0.token = testToken } // the same value is no change
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testUnchangedStateIsResentAfterSevenDays() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        clock.advance(days: 7.1)
        await e.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
    }

    func testChangesWithinTheDebounceWindowAreOneRequest() async {
        let e = engine(debounce: 0.2, realSleep: true)
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.update { $0.userId = "u_1" }
        await e.update { $0.tags = ["pro", "beta"] }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        XCTAssertEqual(sentBodies.first?["tags"] as? [String], ["beta", "pro"])
    }

    func testForbiddenStartsOverOnceWithANewDeviceID() async {
        identity.save(deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA", secret: "lost-secret")
        answer([.json(403, ["error": ["code": "forbidden", "message": "x"]])])
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        let urls = StubURLProtocol.recorded.map { $0.request.url!.lastPathComponent }
        XCTAssertEqual(urls.count, 2, "one retry, never a loop")
        XCTAssertEqual(urls[0], "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA")
        XCTAssertNotEqual(urls[1], urls[0])
        XCTAssertNil(StubURLProtocol.recorded[1].request.value(forHTTPHeaderField: "X-Device-Secret"))
        let result = await e.lastResult
        XCTAssertEqual(result?.error, .forbidden)
    }

    func testForbiddenThenSuccessKeepsTheNewIdentity() async {
        identity.save(deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA", secret: "lost-secret")
        answer([.json(403, ["error": ["code": "forbidden", "message": "x"]]), .json(201, ["deviceId": "x", "deviceSecret": "fresh"])])
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertNotEqual((try? identity.load())??.deviceID, "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA")
        XCTAssertEqual((try? identity.load())??.secret, "fresh")
    }

    func testRetryAfterIsHonored() async {
        answer([.json(429, ["error": ["code": "rate_limited", "message": "x"]], headers: ["Retry-After": "7"]), .json(201, ["deviceId": "x", "deviceSecret": "s"])])
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        XCTAssertTrue(sleeper.waits.contains(7), "\(sleeper.waits)")
    }

    func testTransientFailuresBackOffAndKeepTheChange() async {
        answer([.json(503, [:]), .failure(.timedOut), .json(201, ["deviceId": "x", "deviceSecret": "s"])])
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox; $0.userId = "u_1" }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 3)
        let backoffs = sleeper.waits.filter { $0 > 0 }
        XCTAssertEqual(backoffs.count, 2)
        XCTAssertTrue((0.5...1.0).contains(backoffs[0]) && (1.0...2.0).contains(backoffs[1]), "\(backoffs)")
        XCTAssertEqual(store.load()?.lastSent?.userId, "u_1")
    }

    func testARejectedRegistrationIsNotRetriedButStaysPending() async {
        answer([.json(400, ["error": ["code": "bundle_mismatch", "message": "x"]])])
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        XCTAssertNil(store.load()?.lastSent)
        let result = await e.lastResult
        XCTAssertEqual(result?.error, .rejected(code: "bundle_mismatch", message: "x"))
    }

    func testFirstRegistrationStoresTheSecret() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        let saved = (try? identity.load()) ?? nil
        XCTAssertNotNil(saved?.deviceID.range(of: "^dev_[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression))
        XCTAssertEqual(saved?.secret, "secret-1")
        XCTAssertEqual(StubURLProtocol.recorded.first?.request.url?.lastPathComponent, saved?.deviceID)
    }

    func testALockedKeychainSendsNothingAndMintsNoNewIdentity() async {
        let locked = LockedIdentityStore()
        let e = engine(identityStore: locked)
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
        XCTAssertEqual(locked.saves, 0, "never replace an identity we couldn't read")
        XCTAssertNil(store.load()?.lastSent, "the change stays pending")
    }

    func testAFreshIdentityDropsATokenRestoredFromAnotherDevice() async {
        // A backup restored onto a new phone brings the state file but not the Keychain.
        var restored = PersistedState(desired: base)
        restored.desired.token = String(repeating: "b", count: 64)
        restored.desired.environment = .production
        restored.desired.userId = "u_1"
        restored.lastSent = restored.desired.payload()
        restored.lastSyncAt = clock.now.addingTimeInterval(-30 * 86_400)
        store.save(restored)
        let e = engine(freshIdentity: true)
        await e.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0, "the old phone's token is never sent")
        await e.update { $0.token = testToken }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        XCTAssertEqual(sentBodies.first?["token"] as? String, testToken)
        XCTAssertEqual(sentBodies.first?["userId"] as? String, "u_1", "the user's own settings come along")
    }

    func testEachAppKeepsItsOwnStateFile() {
        let a = FileStateStore.standard(bundleID: "com.example.a").directory.path
        let b = FileStateStore.standard(bundleID: "com.example.b").directory.path
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix("Pushwren/com.example.a"), a)
    }

    func testFileStateStoreRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = FileStateStore(directory: dir)
        XCTAssertNil(fileStore.load())
        var state = PersistedState(desired: base)
        state.desired.userId = "u_1"
        state.lastSyncAt = clock.now
        fileStore.save(state)
        XCTAssertEqual(FileStateStore(directory: dir).load(), state)
        try? FileManager.default.removeItem(at: dir)
    }
}
