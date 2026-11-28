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

/// A state file that exists but can't be decoded (a downgrade, say).
final class UnreadableStateStore: StateStore, @unchecked Sendable {
    func load() -> PersistedState? { nil }
    var exists: Bool { true }
    func save(_ state: PersistedState) {}
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

    private func engine(debounce: TimeInterval = 0, realSleep: Bool = false, freshIdentity: Bool = false, identityStore: IdentityStore? = nil, manual: Bool = false) -> SyncEngine {
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
            freshIdentity: freshIdentity,
            manual: manual
        )
    }

    private var methods: [String] { StubURLProtocol.recorded.map { $0.request.httpMethod ?? "?" } }

    /// The JSON body of the i-th request, or an empty one when there is no such request.
    private func body(_ i: Int) -> [String: Any] { i < sentBodies.count ? sentBodies[i] : [:] }

    private var sentBodies: [[String: Any]] {
        StubURLProtocol.recorded.compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
    }

    func testNothingIsSentBeforeATokenArrives() async {
        let e = engine()
        await e.update { $0.userId = "u_1" }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
    }

    func testPutCarriesNoTagsOrUserID() async {
        let e = engine()
        await e.setUser("u_1", signature: nil)
        await e.addTags(["pro"])
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        let put = StubURLProtocol.recorded.first { $0.request.httpMethod == "PUT" }
        let body = put.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
        XCTAssertNotNil(body?["token"])
        XCTAssertNil(body?["tags"])
        XCTAssertNil(body?["userId"])
    }

    func testTagsAddedBeforeTheTokenGoOutAsOnePatchAfterRegistration() async {
        let e = engine()
        await e.setUser("u_1", signature: nil)
        await e.addTags(["pro"])
        await e.addTags(["team-warriors"])
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(methods, ["PUT", "PATCH"])
        let patch = sentBodies[1]
        XCTAssertEqual(patch["addTags"] as? [String], ["pro", "team-warriors"])
        XCTAssertEqual(patch["userId"] as? String, "u_1")
        XCTAssertEqual(StubURLProtocol.recorded[1].request.value(forHTTPHeaderField: "X-Device-Secret"), "secret-1")
        XCTAssertNil(store.load()?.pending.patch(), "nothing left pending")
    }

    func testAChangeMadeDuringAPatchGoesOutNext() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        let made = OSAllocatedUnfairLock(initialState: false)
        StubURLProtocol.answer { r in
            if r.request.httpMethod == "PATCH", !made.withLock({ m in defer { m = true }; return m }) {
                Task { await e.addTags(["late"]) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return .json(200, ["deviceId": "x"])
        }
        await e.addTags(["early"])
        await e.settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await e.settle()
        let adds = sentBodies.compactMap { $0["addTags"] as? [String] }
        XCTAssertEqual(adds.first, ["early"])
        XCTAssertTrue(adds.contains(["late"]), "\(adds)")
    }

    func testWeeklyRefreshIsAPutWithoutTags() async {
        answer([.json(201, ["deviceId": "x", "deviceSecret": "s"]), .json(200, ["deviceId": "x"])])
        let e = engine()
        await e.addTags(["pro"])
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        clock.advance(days: 7.1)
        await e.syncIfNeeded()
        XCTAssertEqual(methods, ["PUT", "PATCH", "PUT"])
        XCTAssertNil(sentBodies[2]["tags"])
    }

    func testANewIdentityReappliesTheAppsTagsAndUser() async {
        let e = engine()
        await e.setUser("u_1", signature: nil)
        await e.addTags(["pro"])
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(methods, ["PUT", "PATCH"])
        // The server lost the record (or the secret): 403 starts over, and the new record gets everything again.
        answer([.json(403, ["error": ["code": "forbidden", "message": "x"]]), .json(201, ["deviceId": "x", "deviceSecret": "fresh"]), .json(200, ["deviceId": "x"])])
        await e.update { $0.appVersion = "2.0" }
        await e.settle()
        XCTAssertEqual(methods, ["PUT", "PUT", "PATCH"])
        XCTAssertEqual(sentBodies[2]["addTags"] as? [String], ["pro"])
        XCTAssertEqual(sentBodies[2]["userId"] as? String, "u_1")
    }

    func testVersion1StateMigratesWithNothingPending() async throws {
        // What 0.1.x saved: tags and userId inside desired and lastSent, no pending, no version.
        let v1 = """
        {"desired":{"token":"\(testToken)","environment":"sandbox","platform":"ios","bundleId":"com.pushwren.sample","userId":"u_1","tags":["pro"],"sdkVersion":"0.1.0"},
         "lastSent":{"token":"\(testToken)","environment":"sandbox","platform":"ios","bundleId":"com.pushwren.sample","userId":"u_1","tags":["pro"],"sdkVersion":"0.1.0"},
         "lastSyncAt":\(clock.now.timeIntervalSinceReferenceDate)}
        """
        let decoded = try JSONDecoder().decode(PersistedState.self, from: Data(v1.utf8))
        XCTAssertEqual(decoded.desired.tags, ["pro"])
        XCTAssertEqual(decoded.desired.userId, "u_1")
        XCTAssertNil(decoded.pending.patch())
        var migrated = decoded
        migrated.lastSentHost = key.apiBaseURL.host
        store.save(migrated)
        identity.save(deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA", secret: "s")
        let e = engine()
        await e.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0, "the server already has 0.1.x's tags and user")
    }

    func testANewAPIHostForcesARegistration() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        var state = store.load()!
        state.lastSentHost = "api.other.example"
        store.save(state)
        let again = engine()
        await again.syncIfNeeded()
        XCTAssertEqual(methods, ["PUT", "PUT"])
    }

    func testPendingChangeIsSentAfterRelaunch() async {
        // First launch: the change is saved, but the app is gone before it syncs.
        let first = engine(debounce: 60, realSleep: true)
        await first.update { $0.token = testToken; $0.environment = .sandbox }
        await first.setUser("u_1", signature: nil)
        await first.stop()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
        // Next launch, with nothing called again.
        let second = engine()
        await second.syncIfNeeded()
        XCTAssertEqual(methods, ["PUT", "PATCH"])
        XCTAssertEqual(sentBodies[1]["userId"] as? String, "u_1")
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
        await e.update { $0.appVersion = "2.0" }
        await e.addTags(["pro"])
        await e.addTags(["beta"])
        await e.settle()
        XCTAssertEqual(methods, ["PUT", "PATCH"])
        XCTAssertEqual(sentBodies[0]["appVersion"] as? String, "2.0")
        XCTAssertEqual(sentBodies[1]["addTags"] as? [String], ["beta", "pro"])
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
        await e.update { $0.token = testToken; $0.environment = .sandbox; $0.appVersion = "2.0" }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 3)
        let backoffs = sleeper.waits.filter { $0 > 0 }
        XCTAssertEqual(backoffs.count, 2)
        XCTAssertTrue((0.5...1.0).contains(backoffs[0]) && (1.0...2.0).contains(backoffs[1]), "\(backoffs)")
        XCTAssertEqual(store.load()?.lastSent?.appVersion, "2.0")
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
        XCTAssertEqual(methods, ["PUT", "PATCH"])
        XCTAssertEqual(sentBodies.first?["token"] as? String, testToken)
        XCTAssertEqual(sentBodies[1]["userId"] as? String, "u_1", "the user's own settings come along")
    }

    // MARK: Reinstall (TracQR dogfooding, 0.3.0)

    func testAReinstallClearsTheServersUserAndTags() async {
        // The Keychain survives an uninstall; Application Support (the state file) doesn't.
        identity.save(deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA", secret: "kept")
        answer([.json(200, ["deviceId": "x"])])
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(methods, ["PUT", "PATCH"])
        XCTAssertEqual(body(0)["tags"] as? [String], [], "the registration replaces the old tags with none")
        XCTAssertTrue(body(1).keys.contains("userId") && body(1)["userId"] is NSNull, "then the user is cleared: \(body(1))")
        // The next launch, with the state file now saved, sends neither again.
        let relaunch = engine()
        clock.advance(days: 8)
        await relaunch.syncIfNeeded()
        XCTAssertEqual(methods, ["PUT", "PATCH", "PUT"])
        XCTAssertNil(body(2)["tags"])
    }

    func testAReinstallKeepsAUserSetDuringLaunch() async {
        identity.save(deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA", secret: "kept")
        answer([.json(200, ["deviceId": "x"])])
        let e = engine()
        await e.setUser("u_2", signature: nil)
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(methods, ["PUT", "PATCH"])
        XCTAssertEqual(body(0)["tags"] as? [String], [])
        XCTAssertEqual(body(1)["userId"] as? String, "u_2")
    }

    func testAFirstInstallSendsNoEmptyTagList() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(methods, ["PUT"])
        XCTAssertNil(body(0)["tags"])
    }

    // MARK: Sign-out and user changes

    func testAUserChangeWakesARetryWaitingOnTheServer() async {
        // An installed app with its record on the server, signed in.
        identity.save(deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA", secret: "s")
        var installed = PersistedState(desired: base)
        installed.desired.userId = "u_1"
        store.save(installed)
        answer([.json(429, ["error": ["code": "rate_limited", "message": "x"]], headers: ["Retry-After": "120"]), .json(200, ["deviceId": "x"])])
        let e = engine(realSleep: true)
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        for _ in 0..<100 where StubURLProtocol.recorded.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        let started = Date()
        await e.clearUser()
        await e.settle()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "sign-out doesn't wait out a two-minute retry")
        XCTAssertEqual(methods, ["PUT", "PUT", "PATCH"])
        XCTAssertTrue(body(2)["userId"] is NSNull)
    }

    func testSyncIfNeededWakesARetryWaitingOnTheServer() async {
        answer([.json(429, ["error": ["code": "rate_limited", "message": "x"]], headers: ["Retry-After": "120"]), .json(201, ["deviceId": "x", "deviceSecret": "s"])])
        let e = engine(realSleep: true)
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        for _ in 0..<100 where StubURLProtocol.recorded.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        let started = Date()
        await e.syncIfNeeded()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "returning to the foreground tries again now")
        XCTAssertEqual(methods, ["PUT", "PUT"])
    }

    func testTheSameUserIDTwiceInOneLaunchIsSentOnce() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.setUser("u_1", signature: nil)
        await e.settle()
        await e.setUser("u_1", signature: nil)
        await e.settle()
        XCTAssertEqual(methods, ["PUT", "PATCH"])
        // A new launch sends it once more, in case the developer's server changed the user meanwhile.
        let relaunch = engine()
        await relaunch.setUser("u_1", signature: nil)
        await relaunch.settle()
        XCTAssertEqual(methods, ["PUT", "PATCH", "PATCH"])
    }

    func testARejectedTagChangeDoesNotTakeTheUserChangeWithIt() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        answer([.json(400, ["error": ["code": "too_many_tags", "message": "at most 50"]]), .json(200, ["deviceId": "x"])])
        await e.addTags(["pro"])
        await e.setUser("u_1", signature: nil)
        await e.settle()
        // answer() starts a new request log: the two PATCHes since the registration.
        XCTAssertEqual(methods, ["PATCH", "PATCH"])
        XCTAssertEqual(body(1)["userId"] as? String, "u_1")
        XCTAssertNil(body(1)["addTags"], "the rejected tags are dropped")
        XCTAssertNil(store.load()?.pending.patch(), "nothing left pending")
    }

    // MARK: Diagnostics and deleting the device

    func testARejectedChangeIsKeptForDiagnostics() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        answer([.json(400, ["error": ["code": "too_many_tags", "message": "at most 50"]])])
        await e.addTags(["pro"])
        await e.settle()
        let rejected = await e.lastRejected
        XCTAssertEqual(rejected?.error, .rejected(code: "too_many_tags", message: "at most 50"))
        let result = await e.lastResult
        XCTAssertEqual(Diagnostics.lastError(registration: nil, result: result, rejected: rejected), "dropped a change the server rejected: too_many_tags: at most 50")
    }

    func testAMissingUserSignatureKeepsTheDeviceAndDropsTheUserChange() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        let before = (try? identity.load())??.deviceID
        answer([.json(403, ["error": ["code": "invalid_user_signature", "message": "userIdSignature is missing or wrong"]])])
        await e.setUser("u_1", signature: nil)
        await e.settle()
        XCTAssertEqual(methods, ["PATCH"], "no new registration")
        XCTAssertEqual((try? identity.load())??.deviceID, before, "identity verification never costs the device its ID")
        let rejected = await e.lastRejected
        XCTAssertEqual(rejected?.error, .rejected(code: "invalid_user_signature", message: "userIdSignature is missing or wrong"))
        XCTAssertNil(store.load()?.pending.patch())
    }

    func testTheLastSyncSurvivesARelaunch() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        let synced = clock.now
        clock.advance(days: 1)
        let relaunch = engine()
        let result = await relaunch.lastResult
        let saved = await relaunch.lastSyncAt
        XCTAssertNil(result)
        XCTAssertEqual(saved, synced)
        XCTAssertEqual(Diagnostics.lastSync(result: result, saved: saved), synced)
    }

    func testDeleteRemovesTheRecordAndStartsOverAnonymous() async {
        let e = engine()
        await e.setUser("u_1", signature: nil)
        await e.addTags(["pro"])
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        let id = (try? identity.load())??.deviceID
        answer([.json(204, [:])])
        let deleted = await e.deleteRecord()
        XCTAssertTrue(deleted)
        XCTAssertEqual(methods, ["DELETE"])
        XCTAssertEqual(StubURLProtocol.recorded.first?.request.url?.lastPathComponent, id)
        XCTAssertEqual(StubURLProtocol.recorded.first?.request.value(forHTTPHeaderField: "X-Device-Secret"), "secret-1")
        XCTAssertNil((try? identity.load()) ?? nil, "a new device ID next time")
        let desired = await e.desired
        XCTAssertNil(desired.userId)
        XCTAssertEqual(desired.tags, [])
        XCTAssertNil(store.load()?.pending.patch())
        XCTAssertNil(store.load()?.lastSent)
    }

    func testAFailedDeleteKeepsEverything() async {
        let e = engine()
        await e.setUser("u_1", signature: nil)
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        answer([.json(503, [:])])
        let deleted = await e.deleteRecord()
        XCTAssertFalse(deleted)
        XCTAssertNotNil((try? identity.load()) ?? nil)
        let desired = await e.desired
        XCTAssertEqual(desired.userId, "u_1")
    }

    // MARK: Review fixes

    func testDeleteDoesNotWaitOutARetry() async {
        answer([.json(429, ["error": ["code": "rate_limited", "message": "x"]], headers: ["Retry-After": "120"]), .json(204, [:])])
        identity.save(deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA", secret: "s")
        store.save(PersistedState(desired: base))
        let e = engine(realSleep: true)
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        for _ in 0..<100 where StubURLProtocol.recorded.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        let started = Date()
        let deleted = await e.deleteRecord()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "deleting an account never waits out a backoff")
        XCTAssertTrue(deleted)
        XCTAssertEqual(methods, ["PUT", "DELETE"])
    }

    func testASignatureRejectionKeepsTheTags() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        answer([.json(403, ["error": ["code": "invalid_user_signature", "message": "userIdSignature is missing or wrong"]]), .json(200, ["deviceId": "x"])])
        await e.addTags(["pro"])
        await e.setUser("u_1", signature: nil)
        await e.settle()
        XCTAssertEqual(methods, ["PATCH", "PATCH"])
        XCTAssertEqual(body(1)["addTags"] as? [String], ["pro"], "the tags go again")
        XCTAssertNil(body(1)["userId"], "the unsigned user is dropped")
        XCTAssertNil(store.load()?.pending.patch())
    }

    func testADeleteAnsweredForbiddenStillForgetsTheDevice() async {
        let e = engine()
        await e.setUser("u_1", signature: nil)
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        answer([.json(403, ["error": ["code": "forbidden", "message": "missing or wrong device secret"]])])
        let deleted = await e.deleteRecord()
        XCTAssertTrue(deleted, "the server has no record under our secret: nothing is left to delete")
        XCTAssertNil((try? identity.load()) ?? nil)
    }

    func testNoSyncStartsWhileADeleteIsInFlight() async {
        let e = engine()
        await e.setUser("u_1", signature: nil)
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        StubURLProtocol.answer { r in
            if r.request.httpMethod == "DELETE" {
                Task { await e.addTags(["late"]) }
                Thread.sleep(forTimeInterval: 0.1)
                return .json(204, [:])
            }
            return .json(201, ["deviceId": "x", "deviceSecret": "new"])
        }
        let deleted = await e.deleteRecord()
        XCTAssertTrue(deleted)
        await e.settle()
        let urls = StubURLProtocol.recorded.map { "\($0.request.httpMethod ?? "?") \($0.request.url!.lastPathComponent)" }
        XCTAssertEqual(urls.first?.hasPrefix("DELETE"), true, "\(urls)")
        XCTAssertFalse(urls.dropFirst().contains { $0.hasPrefix("PUT dev_") && $0.hasSuffix(urls[0].split(separator: " ")[1]) }, "the deleted ID is never registered again: \(urls)")
        XCTAssertFalse(sentBodies.contains { ($0["userId"] as? String) == "u_1" }, "the deleted user is never re-applied")
    }

    func testAnUnreadableStateFileIsNotTakenForAReinstall() async {
        identity.save(deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA", secret: "kept")
        let unreadable = UnreadableStateStore()
        answer([.json(200, ["deviceId": "x"])])
        let e = SyncEngine(client: APIClient(key: key, session: StubURLProtocol.session()), identity: identity, store: unreadable, initial: base, now: { [clock] in clock!.now }, sleep: { _ in }, debounce: 0)
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(methods, ["PUT"])
        XCTAssertNil(body(0)["tags"], "a file we can't read is not a reinstall: the server's tags stay")
    }

    func testTheRegistrationSaysWhetherTheAppHasPushwrensExtension() async {
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox; $0.serviceExtension = true }
        await e.settle()
        XCTAssertEqual(methods, ["PUT"])
        XCTAssertEqual(body(0)["serviceExtension"] as? Bool, true)
        await e.update { $0.serviceExtension = false }
        await e.settle()
        XCTAssertEqual(methods, ["PUT", "PUT"], "a change is a new registration")
        XCTAssertEqual(body(1)["serviceExtension"] as? Bool, false)
    }

    func testAFoundExtensionIsRememberedForTheAppVersionAndBuild() async {
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let found: @Sendable () -> Bool = { scans.withLock { $0 += 1 }; return true }
        let first = await engine().serviceExtension(appVersion: "1.2", build: "7", detect: found)
        XCTAssertTrue(first)
        let relaunch = await engine().serviceExtension(appVersion: "1.2", build: "7", detect: { XCTFail("scanned again"); return false })
        XCTAssertTrue(relaunch, "the saved answer")
        _ = await engine().serviceExtension(appVersion: "1.2", build: "8", detect: found)
        _ = await engine().serviceExtension(appVersion: "1.3", build: "8", detect: found)
        XCTAssertEqual(scans.withLock { $0 }, 3, "a new build or version looks again")
    }

    func testAnAppWithoutTheExtensionIsCheckedAgainAtEachLaunch() async {
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let missing: @Sendable () -> Bool = { scans.withLock { $0 += 1 }; return false }
        let first = await engine().serviceExtension(appVersion: "1.2", build: "7", detect: missing)
        let relaunch = await engine().serviceExtension(appVersion: "1.2", build: "7", detect: missing)
        let added = await engine().serviceExtension(appVersion: "1.2", build: "7", detect: { true })
        XCTAssertFalse(first)
        XCTAssertFalse(relaunch)
        XCTAssertTrue(added, "added during development, same build number")
        XCTAssertEqual(scans.withLock { $0 }, 2)
    }

    func testTheDefaultLogLevelShowsRegistrations() {
        XCTAssertEqual(Log.defaultLevel, .info)
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

    // MARK: Manual registration and deleted stays deleted (0.6.0)

    private static let deletedAnswer = StubURLProtocol.Answer.json(410, ["error": ["code": "device_deleted", "message": "Device was deleted"]])

    /// A phone registered under device ID "secret-1"'s record, with a user and a tag the server took.
    private func registered(manual: Bool = false) async -> SyncEngine {
        let e = engine(manual: manual)
        if manual { _ = await e.register() }
        await e.setUser("u_1", signature: nil)
        await e.addTags(["pro"])
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        return e
    }

    func testManualModeSendsNothingAndAsksForNoTokenBeforeRegister() async {
        let e = engine(manual: true)
        let asks = await e.mayRequestToken
        XCTAssertFalse(asks, "no token is asked of iOS before register()")
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
    }

    func testManualModeKeepsSetUserIDAndTagsMadeBeforeRegisterAndSendsThemWithIt() async {
        let e = engine(manual: true)
        await e.setUser("u_9", signature: nil)
        await e.addTags(["beta"])
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
        let started = await e.register()
        XCTAssertTrue(started)
        await e.settle()
        XCTAssertEqual(methods, ["PUT", "PATCH"])
        XCTAssertEqual(body(1)["userId"] as? String, "u_9")
        XCTAssertEqual(body(1)["addTags"] as? [String], ["beta"])
    }

    func testARegisteredPhoneInManualModeSyncsAtLaunchWithoutRegister() async {
        _ = await registered()
        answer([.json(200, ["deviceId": "x"])])
        let relaunch = engine(manual: true)
        let asks = await relaunch.mayRequestToken
        XCTAssertTrue(asks)
        clock.advance(days: 8)
        await relaunch.syncIfNeeded()
        XCTAssertEqual(methods, ["PUT"], "the refresh goes out with no register()")
    }

    func testDeviceDeletedStopsThePhoneAndForgetsIDUserTagsAndPendingChanges() async {
        let e = await registered()
        answer([Self.deletedAnswer])
        await e.addTags(["late"])
        await e.recordOpen("ntf_1")
        await e.settle()
        XCTAssertEqual(methods.last, "PATCH")
        let stopped = await e.stopped
        XCTAssertEqual(stopped, .deleted)
        XCTAssertNil((try? identity.load()) ?? nil, "the device ID is forgotten")
        let desired = await e.desired
        XCTAssertNil(desired.userId)
        XCTAssertEqual(desired.tags, [])
        XCTAssertNil(store.load()?.pending.patch())
        XCTAssertEqual(store.load()?.opens, [])
        XCTAssertEqual(store.load()?.stopped, .deleted)
        let asks = await e.mayRequestToken
        XCTAssertFalse(asks)
        let result = await e.lastResult
        XCTAssertNil(result?.error, "stopping is not a sync failure")
    }

    func testTheStopSurvivesARelaunch() async {
        let e = await registered()
        answer([Self.deletedAnswer])
        await e.addTags(["late"])
        await e.settle()
        let before = StubURLProtocol.recorded.count
        // The next launch: the Keychain had no identity, so the runtime saved a new one.
        identity.save(deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRZ", secret: nil)
        let relaunch = engine(freshIdentity: true)
        await relaunch.update { $0.token = testToken; $0.environment = .sandbox }
        await relaunch.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.count, before)
        let stopped = await relaunch.stopped
        XCTAssertEqual(stopped, .deleted)
    }

    func testWhileStoppedForegroundANewTokenSetUserIDTagsAndActivityTokensSendNothing() async {
        let e = await registered()
        answer([Self.deletedAnswer])
        await e.addTags(["late"])
        await e.settle()
        let before = StubURLProtocol.recorded.count
        await e.update { $0.token = String(repeating: "b", count: 64) }
        await e.setUser("u_2", signature: nil)
        await e.clearUser()
        await e.addTags(["x"])
        await e.removeTags(["pro"])
        await e.reportActivity(.token(key: "order-42", token: String(repeating: "c", count: 64), attributesType: "OrderAttributes"))
        await e.recordOpen("ntf_2")
        await e.syncIfNeeded()
        XCTAssertEqual(StubURLProtocol.recorded.count, before)
        XCTAssertNil(store.load()?.pending.patch())
        XCTAssertEqual(store.load()?.pending.activities, [])
        XCTAssertEqual(store.load()?.opens, [])
        let desired = await e.desired
        XCTAssertNil(desired.userId)
        XCTAssertEqual(desired.tags, [])
    }

    func testRegisterRestartsAStoppedPhoneWithANewDeviceID() async {
        let e = await registered()
        let old = StubURLProtocol.recorded[0].request.url!.lastPathComponent
        answer([Self.deletedAnswer])
        await e.addTags(["late"])
        await e.settle()
        answer([.json(201, ["deviceId": "x", "deviceSecret": "secret-2"])])
        let started = await e.register()
        XCTAssertTrue(started)
        await e.settle()
        XCTAssertEqual(methods, ["PUT"])
        let fresh = StubURLProtocol.recorded[0].request.url!.lastPathComponent
        XCTAssertNotEqual(fresh, old)
        XCTAssertEqual((try? identity.load())??.secret, "secret-2")
        let stopped = await e.stopped
        XCTAssertNil(stopped)
        XCTAssertNil(store.load()?.stopped)
    }

    func testDeleteDeviceEndsStopped() async {
        let e = await registered()
        answer([.json(204, [:])])
        let deleted = await e.deleteRecord()
        XCTAssertTrue(deleted)
        let stopped = await e.stopped
        XCTAssertEqual(stopped, .deleted)
        clock.advance(days: 8)
        await e.update { $0.token = String(repeating: "b", count: 64) }
        await e.syncIfNeeded()
        XCTAssertEqual(methods, ["DELETE"], "no registration until register()")
    }

    func testAReinstallLaunchThatGets410StartsFreshWithANewID() async {
        // The Keychain survives an uninstall; the state file doesn't.
        identity.save(deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA", secret: "kept")
        answer([Self.deletedAnswer, .json(201, ["deviceId": "x", "deviceSecret": "fresh"])])
        let e = engine()
        await e.update { $0.token = testToken; $0.environment = .sandbox }
        await e.settle()
        let urls = StubURLProtocol.recorded.map { $0.request.url!.lastPathComponent }
        XCTAssertEqual(urls.first, "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA")
        XCTAssertNotEqual(urls[1], urls[0])
        XCTAssertEqual((try? identity.load())??.secret, "fresh")
        let stopped = await e.stopped
        XCTAssertNil(stopped)
    }

    func testRegisterOnARegisteredPhoneDoesNothing() async {
        let e = await registered()
        let before = StubURLProtocol.recorded.count
        let started = await e.register()
        XCTAssertFalse(started)
        await e.settle()
        XCTAssertEqual(StubURLProtocol.recorded.count, before)
    }
}
