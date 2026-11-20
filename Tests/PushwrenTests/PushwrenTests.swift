import Foundation
import os
import XCTest
@testable import Pushwren

@MainActor
final class PushwrenTests: XCTestCase {
    private let devKey = "pk_dev_AbCdEfGhIjKlMnOpQrStUvWxYz012345"
    private var started: OSAllocatedUnfairLock<[String]>!
    private var registered: OSAllocatedUnfairLock<Int>!
    private var savedHooks: Pushwren.Hooks!

    override func setUp() async throws {
        savedHooks = Pushwren.hooks
        let started = OSAllocatedUnfairLock<[String]>(initialState: [])
        let registered = OSAllocatedUnfairLock(initialState: 0)
        self.started = started
        self.registered = registered
        Pushwren.hooks = Pushwren.Hooks(
            start: { key, _ in started.withLock { $0.append(key.raw) } },
            registerForRemoteNotifications: { registered.withLock { $0 += 1 } }
        )
    }

    override func tearDown() async throws {
        Pushwren.hooks = savedHooks
    }

    func testConfigureWithASecretKeyLogsAndDoesNothing() {
        Pushwren.configure(appKey: "sk_dev_AbCdEfGhIjKlMnOpQrStUvWxYz012345")
        Pushwren.configure(appKey: "not a key")
        XCTAssertEqual(started.withLock { $0 }, [])
        XCTAssertEqual(registered.withLock { $0 }, 0)
    }

    func testConfigureStartsTheRuntimeAndRegistersForRemoteNotifications() {
        Pushwren.configure(appKey: devKey)
        XCTAssertEqual(started.withLock { $0 }, [devKey])
        XCTAssertEqual(registered.withLock { $0 }, 1)
    }

    func testConfigureReturnsInUnder5ms() {
        var times: [Double] = []
        for _ in 0..<50 {
            let start = DispatchTime.now().uptimeNanoseconds
            Pushwren.configure(appKey: devKey)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: "configure median: %.4f ms", median))
        XCTAssertLessThan(median, 5, "median configure time \(median) ms")
    }

    func testDeviceTokenBytesBecomeLowercaseHex() {
        XCTAssertEqual(Pushwren.hex(Data([0x00, 0xAB, 0x0F, 0xFF])), "00ab0fff")
    }

    func testDiagnosticsShowOnlyTheTokenTail() {
        let token = "0123456789abcdef" + String(repeating: "a", count: 40) + "deadbeef"
        let d = Diagnostics(
            deviceID: "dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA",
            token: token,
            environment: .sandbox,
            environmentWarning: nil,
            permission: .authorized,
            apiHost: "api.dev.pushwren.com",
            lastSync: nil,
            lastError: nil
        )
        XCTAssertFalse(d.description.contains(token))
        XCTAssertFalse(String(describing: d.token).contains("0123456789"))
        XCTAssertTrue(d.description.contains("deadbeef"))
        XCTAssertTrue(d.description.contains("dev_01JD3Q8Z4T7M2K9XW5B6C0HFRA"))
    }

    func testAuthorizationStatusesMapFromUserNotifications() {
        XCTAssertEqual(AuthorizationStatus(.authorized), .authorized)
        XCTAssertEqual(AuthorizationStatus(.provisional), .provisional)
        XCTAssertEqual(AuthorizationStatus(.denied), .denied)
        XCTAssertEqual(AuthorizationStatus(.notDetermined), .notDetermined)
    }
}
