import os
import UserNotifications
import XCTest
@testable import PushwrenNotificationService

/// Records every call of a content handler; `first` waits for the first one.
private final class HandlerCalls: @unchecked Sendable {
    private let calls = OSAllocatedUnfairLock<[UNNotificationContent]>(uncheckedState: [])
    let called = XCTestExpectation(description: "content handler called")

    var handler: (UNNotificationContent) -> Void {
        { content in
            self.calls.withLockUnchecked { $0.append(content) }
            self.called.fulfill()
        }
    }

    var all: [UNNotificationContent] { calls.withLockUnchecked { $0 } }
}

final class PushwrenExtensionTests: XCTestCase {
    private let notificationID = "ntf_01JD3Q8Z4T7M2K9XW5B6C0HFRA"
    private let localBase = URL(string: "http://127.0.0.1:4010")!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pushwren-nse-tests-\(UUID().uuidString)")
        StubURLProtocol.answer { _ in .response(status: 204) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var configuration: PushwrenExtension.Configuration {
        .init(session: StubURLProtocol.session(), localReceiptBaseURL: localBase, directory: directory)
    }

    private func request(_ userInfo: [AnyHashable: Any]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Order shipped"
        content.body = "It's on the way."
        content.userInfo = ["aps": ["alert": ["title": "Order shipped"], "mutable-content": 1]].merging(userInfo) { $1 }
        return UNNotificationRequest(identifier: "r1", content: content, trigger: nil)
    }

    /// Runs the helper on a push and waits for the content handler.
    @discardableResult
    private func run(
        _ userInfo: [AnyHashable: Any],
        configuration: PushwrenExtension.Configuration? = nil
    ) async -> (delivered: UNNotificationContent, request: UNNotificationRequest, calls: HandlerCalls) {
        let request = request(userInfo)
        let calls = HandlerCalls()
        _ = PushwrenExtension.handle(request, contentHandler: calls.handler, configuration: configuration ?? self.configuration)
        await fulfillment(of: [calls.called], timeout: 5)
        guard let delivered = calls.all.first else {
            XCTFail("the content handler never ran")
            return (UNNotificationContent(), request, calls)
        }
        return (delivered, request, calls)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func leftoverFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: - Receipts

    func testAReceiptPostsToTheHostItsFirstCharacterNames() async throws {
        for (code, url) in [
            ("pAQIDBAUGBwg", "https://api.pushwren.com/v1/receipts"),
            ("dAQIDBAUGBwg", "https://api.dev.pushwren.com/v1/receipts"),
            ("lAQIDBAUGBwg", "http://127.0.0.1:4010/v1/receipts"),
        ] {
            StubURLProtocol.answer { _ in .response(status: 204) }
            let (delivered, request, _) = await run(["_h": notificationID, "_r": code])
            XCTAssertTrue(delivered === request.content, "a push without an image is delivered untouched")
            XCTAssertEqual(StubURLProtocol.recorded.count, 1)
            let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
            XCTAssertEqual(sent.request.url?.absoluteString, url)
            XCTAssertEqual(sent.request.httpMethod, "POST")
            XCTAssertEqual(sent.request.timeoutInterval, 5)
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(sent.request.value(forHTTPHeaderField: "Authorization"), "receipts carry no API key")
            XCTAssertEqual(String(data: sent.body, encoding: .utf8), #"{"notificationId":"\#(notificationID)","receipt":"\#(code)"}"#)
        }
    }

    func testALocalCodeIsIgnoredWithoutAnInjectedBase() async {
        let live = PushwrenExtension.Configuration(session: StubURLProtocol.session(), localReceiptBaseURL: nil, directory: directory)
        let (delivered, request, _) = await run(["_h": notificationID, "_r": "lAQIDBAUGBwg"], configuration: live)
        XCTAssertTrue(delivered === request.content)
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testNothingPostsForAnUnknownServerOrAMissingOrBadNotificationID() async {
        for userInfo: [AnyHashable: Any] in [
            ["_h": notificationID, "_r": "xAQIDBAUGBwg"],
            ["_r": "pAQIDBAUGBwg"],
            ["_h": "ntf_01JD3Q8Z4T7M2K9XW5B6C0HFRI", "_r": "pAQIDBAUGBwg"],
            ["_h": "ntf_short", "_r": "pAQIDBAUGBwg"],
            ["_h": notificationID, "_r": "p has spaces"],
            ["_h": notificationID, "_r": 42],
            ["_h": notificationID, "_r": ""],
        ] {
            let (delivered, request, calls) = await run(userInfo)
            XCTAssertTrue(delivered === request.content)
            XCTAssertEqual(calls.all.count, 1)
            XCTAssertTrue(StubURLProtocol.recorded.isEmpty, "\(userInfo)")
        }
    }

    func testAFailedReceiptStillDeliversOnce() async {
        StubURLProtocol.answer { _ in .response(status: 500) }
        let (delivered, request, calls) = await run(["_h": notificationID, "_r": "pAQIDBAUGBwg"])
        XCTAssertTrue(delivered === request.content)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1, "receipts are best effort: no retry")
    }

    // MARK: - Images

    func testJPEGPNGAndGIFAreAttachedByTheirContent() async throws {
        for (name, ext) in [("one.jpg", "jpg"), ("one.png", "png"), ("one.gif", "gif")] {
            let bytes = try fixture(name)
            // The server's Content-Type and the URL's extension say nothing useful: the bytes decide.
            StubURLProtocol.answer { _ in .response(status: 200, headers: ["Content-Type": "application/octet-stream"], body: bytes) }
            let (delivered, request, _) = await run(["_i": "https://cdn.example.com/picture"])
            XCTAssertEqual(StubURLProtocol.recorded.first?.request.url?.absoluteString, "https://cdn.example.com/picture")
            XCTAssertEqual(delivered.attachments.count, 1, name)
            let attachment = try XCTUnwrap(delivered.attachments.first)
            XCTAssertEqual(attachment.url.pathExtension, ext)
            XCTAssertEqual(try Data(contentsOf: attachment.url), bytes)
            XCTAssertEqual(delivered.title, request.content.title)
            XCTAssertEqual(delivered.body, request.content.body)
            XCTAssertEqual(delivered.userInfo["_i"] as? String, "https://cdn.example.com/picture")
        }
    }

    func testHTMLServedAsAPNGIsNotAttached() async {
        let html = Data("<html><body>Not found</body></html>".utf8)
        StubURLProtocol.answer { _ in .response(status: 200, headers: ["Content-Type": "image/png"], body: html) }
        let (delivered, request, _) = await run(["_i": "https://cdn.example.com/a.png"])
        XCTAssertTrue(delivered === request.content)
        XCTAssertTrue(leftoverFiles().isEmpty, "the download is deleted: \(leftoverFiles())")
    }

    func testAnErrorStatusIsNotAttached() async throws {
        let png = try fixture("one.png")
        StubURLProtocol.answer { _ in .response(status: 404, body: png) }
        let (delivered, _, _) = await run(["_i": "https://cdn.example.com/a.png"])
        XCTAssertTrue(delivered.attachments.isEmpty)
        XCTAssertTrue(leftoverFiles().isEmpty)
    }

    func testAResponsePassingTenMegabytesIsCutOffAndNotAttached() async throws {
        let png = try fixture("one.png")
        let big = png + Data(count: ImageAttacher.maxBytes + 1 - png.count)
        StubURLProtocol.answer { _ in .response(status: 200, body: big) }
        let (delivered, request, _) = await run(["_i": "https://cdn.example.com/huge.png"])
        XCTAssertTrue(delivered === request.content)
        XCTAssertTrue(leftoverFiles().isEmpty)

        // A Content-Length over the limit stops at the headers, before any body arrives.
        StubURLProtocol.answer { _ in .response(status: 200, headers: ["Content-Length": "\(ImageAttacher.maxBytes + 1)"], body: png) }
        let second = await run(["_i": "https://cdn.example.com/huge.png"])
        XCTAssertTrue(second.delivered.attachments.isEmpty)
    }

    func testAnImageOfExactlyTenMegabytesIsKept() async throws {
        XCTAssertEqual(ImageAttacher.maxBytes, 10_000_000)
        let png = try fixture("one.png")
        let exact = png + Data(count: ImageAttacher.maxBytes - png.count)
        StubURLProtocol.answer { _ in .response(status: 200, body: exact) }
        let (delivered, _, _) = await run(["_i": "https://cdn.example.com/big.png"])
        // Apple validates the image itself after the extension finishes; the helper only stops at the limit.
        XCTAssertEqual(delivered.attachments.count, 1)
    }

    func testAnHTTPImageIsNotFetched() async {
        for url in ["http://cdn.example.com/a.png", "ftp://cdn.example.com/a.png", "not a url", ""] {
            let (delivered, request, _) = await run(["_i": url])
            XCTAssertTrue(delivered === request.content)
            XCTAssertTrue(StubURLProtocol.recorded.isEmpty, url)
        }
    }

    func testARedirectIsFollowedOnlyToHTTPS() async throws {
        let png = try fixture("one.png")
        for (target, attached) in [("https://images.example.com/b.png", true), ("http://images.example.com/b.png", false)] {
            StubURLProtocol.answer { recorded in
                recorded.request.url?.host == "cdn.example.com" ? .redirect(to: target) : .response(status: 200, body: png)
            }
            let (delivered, _, _) = await run(["_i": "https://cdn.example.com/a.png"])
            XCTAssertEqual(delivered.attachments.count, attached ? 1 : 0, target)
            XCTAssertEqual(StubURLProtocol.recorded.contains { $0.request.url?.absoluteString == target }, attached, target)
        }
    }

    // MARK: - Together

    func testTheReceiptAndTheImageRunInParallelAndTheHandlerFiresOnce() async throws {
        let png = try fixture("one.png")
        StubURLProtocol.answer { recorded in
            recorded.request.url?.path == "/v1/receipts"
                ? .delayed(1, .response(status: 204))
                : .delayed(1, .response(status: 200, body: png))
        }
        let (delivered, _, calls) = await run(["_h": notificationID, "_r": "pAQIDBAUGBwg", "_i": "https://cdn.example.com/a.png"])
        let started = StubURLProtocol.recorded
        XCTAssertEqual(started.count, 2)
        XCTAssertLessThan(abs(started[0].at.timeIntervalSince(started[1].at)), 0.5, "both requests start before either answers")
        XCTAssertEqual(delivered.attachments.count, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls.all.count, 1)
    }

    func testTheHandlerWaitsForTheReceipt() async throws {
        let png = try fixture("one.png")
        StubURLProtocol.answer { recorded in
            recorded.request.url?.path == "/v1/receipts" ? .delayed(0.5, .response(status: 204)) : .response(status: 200, body: png)
        }
        let started = Date()
        let (delivered, _, _) = await run(["_h": notificationID, "_r": "pAQIDBAUGBwg", "_i": "https://cdn.example.com/a.png"])
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.45)
        XCTAssertEqual(delivered.attachments.count, 1)
    }

    func testASlowReceiptHoldsTheNotificationForAtMostASecond() async throws {
        StubURLProtocol.answer { _ in .delayed(3, .response(status: 204)) }
        let started = Date()
        let (delivered, request, calls) = await run(["_h": notificationID, "_r": "pAQIDBAUGBwg"])
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.9, "it waits the full second for the receipt")
        XCTAssertLessThan(waited, 2)
        XCTAssertTrue(delivered === request.content)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1, "the receipt request was issued and is left running")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.all.count, 1)
    }

    func testAFastReceiptDeliversRightAfterIt() async {
        StubURLProtocol.answer { _ in .delayed(0.2, .response(status: 204)) }
        let started = Date()
        _ = await run(["_h": notificationID, "_r": "pAQIDBAUGBwg"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8, "it does not wait out the second")
    }

    func testAnImageSlowerThanTheWaitIsStillWaitedFor() async throws {
        let png = try fixture("one.png")
        StubURLProtocol.answer { recorded in
            recorded.request.url?.path == "/v1/receipts" ? .delayed(3, .response(status: 204)) : .delayed(1.5, .response(status: 200, body: png))
        }
        let started = Date()
        let (delivered, _, calls) = await run(["_h": notificationID, "_r": "pAQIDBAUGBwg", "_i": "https://cdn.example.com/a.png"])
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 1.4, "the image is waited for")
        XCTAssertLessThan(waited, 2.8, "the receipt is not")
        XCTAssertEqual(delivered.attachments.count, 1)
        XCTAssertEqual(calls.all.count, 1)
    }

    func testTheWaitTimerFiringAfterDeliveryDoesNothing() async throws {
        var short = configuration
        short.receiptWait = 0.3
        StubURLProtocol.answer { _ in .response(status: 204) }
        let (_, _, calls) = await run(["_h": notificationID, "_r": "pAQIDBAUGBwg"], configuration: short)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(calls.all.count, 1)
    }

    func testTimeWillExpireRacingTheWaitDeliversOnce() async throws {
        var short = configuration
        short.receiptWait = 0.2
        StubURLProtocol.answer { _ in .delayed(3, .response(status: 204)) }
        let request = request(["_h": notificationID, "_r": "pAQIDBAUGBwg"])
        let calls = HandlerCalls()
        let handle = PushwrenExtension.handle(request, contentHandler: calls.handler, configuration: short)
        try await Task.sleep(for: .milliseconds(200))
        handle.timeWillExpire()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(calls.all.count, 1)
    }

    func testTheReceiptPostsEvenWhenTheImageFails() async {
        StubURLProtocol.answer { recorded in
            recorded.request.url?.path == "/v1/receipts" ? .response(status: 204) : .failure(.cannotConnectToHost)
        }
        let (delivered, request, _) = await run(["_h": notificationID, "_r": "pAQIDBAUGBwg", "_i": "https://cdn.example.com/a.png"])
        XCTAssertTrue(delivered === request.content)
        XCTAssertEqual(Set(StubURLProtocol.recorded.compactMap { $0.request.url?.path }), ["/v1/receipts", "/a.png"])
    }

    func testTimeWillExpireBeforeTheImageArrivesDeliversWithoutIt() async throws {
        let png = try fixture("one.png")
        StubURLProtocol.answer { recorded in
            recorded.request.url?.path == "/v1/receipts" ? .response(status: 204) : .delayed(0.5, .response(status: 200, body: png))
        }
        let request = request(["_h": notificationID, "_r": "pAQIDBAUGBwg", "_i": "https://cdn.example.com/a.png"])
        let calls = HandlerCalls()
        let handle = PushwrenExtension.handle(request, contentHandler: calls.handler, configuration: configuration)
        handle.timeWillExpire()
        await fulfillment(of: [calls.called], timeout: 1)
        XCTAssertTrue(calls.all[0] === request.content)
        try await Task.sleep(for: .milliseconds(800))
        handle.timeWillExpire()
        XCTAssertEqual(calls.all.count, 1, "the handler never fires twice")
        XCTAssertTrue(leftoverFiles().isEmpty)
    }

    func testTimeWillExpireDeliversAnImageThatIsReady() async throws {
        let png = try fixture("one.png")
        StubURLProtocol.answer { recorded in
            recorded.request.url?.path == "/v1/receipts" ? .delayed(5, .response(status: 204)) : .response(status: 200, body: png)
        }
        let request = request(["_h": notificationID, "_r": "pAQIDBAUGBwg", "_i": "https://cdn.example.com/a.png"])
        let calls = HandlerCalls()
        let handle = PushwrenExtension.handle(request, contentHandler: calls.handler, configuration: configuration)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(calls.all.isEmpty, "still waiting for the receipt")
        handle.timeWillExpire()
        await fulfillment(of: [calls.called], timeout: 1)
        XCTAssertEqual(calls.all.first?.attachments.count, 1)
    }

    func testAPushWithNeitherKeyPassesThroughUntouched() async {
        let request = request(["orderId": "A-1", "_h": notificationID])
        let calls = HandlerCalls()
        let handle = PushwrenExtension.handle(request, contentHandler: calls.handler, configuration: configuration)
        XCTAssertEqual(calls.all.count, 1, "delivered at once")
        XCTAssertTrue(calls.all[0] === request.content)
        handle.timeWillExpire()
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    // MARK: - The extension class and the live configuration

    func testTheExtensionClassRunsTheHelper() async throws {
        let png = try fixture("one.png")
        StubURLProtocol.answer { recorded in
            recorded.request.url?.path == "/v1/receipts" ? .response(status: 204) : .delayed(0.5, .response(status: 200, body: png))
        }
        let service = PushwrenNotificationService()
        service.configuration = configuration
        let calls = HandlerCalls()
        service.didReceive(request(["_h": notificationID, "_r": "lAQIDBAUGBwg", "_i": "https://cdn.example.com/a.png"]), withContentHandler: calls.handler)
        service.serviceExtensionTimeWillExpire()
        await fulfillment(of: [calls.called], timeout: 1)
        XCTAssertTrue(calls.all[0].attachments.isEmpty)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertTrue(StubURLProtocol.recorded.contains { $0.request.url?.absoluteString == "http://127.0.0.1:4010/v1/receipts" })
    }

    func testTheLiveConfiguration() {
        XCTAssertEqual(PushwrenExtension.Configuration.live.directory.lastPathComponent, "com.pushwren.notification-service")
        XCTAssertNil(PushwrenExtension.Configuration.live.localReceiptBaseURL, "an l code posts nothing outside tests")
    }
}
