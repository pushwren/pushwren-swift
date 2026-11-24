import Foundation
import os

/// Intercepts URLSession requests in tests: records each one and answers from a handler.
/// The same pattern as PushwrenTests' stub, plus answers that arrive late (to see two requests in
/// flight at once, or iOS's time running out first) and a record of when each request started.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let request: URLRequest
        let body: Data
        let at: Date
    }

    indirect enum Answer: Sendable {
        case response(status: Int, headers: [String: String] = [:], body: Data = Data())
        case failure(URLError.Code)
        /// The answer, after this many seconds (dropped if the request is cancelled first).
        case delayed(TimeInterval, Answer)
        /// A 302 to this URL.
        case redirect(to: String)
    }

    typealias Handler = @Sendable (Recorded) -> Answer

    private static let state = OSAllocatedUnfairLock<(handler: Handler?, recorded: [Recorded])>(initialState: (nil, []))

    static func answer(with handler: @escaping Handler) {
        state.withLock { $0 = (handler, []) }
        answered.withLock { $0 = 0 }
    }

    private static let answered = OSAllocatedUnfairLock(initialState: 0)

    /// How many requests were answered to the end (not cancelled first) since `answer(with:)`.
    static var answeredCount: Int { answered.withLock { $0 } }

    static var recorded: [Recorded] { state.withLock { $0.recorded } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private let stopped = OSAllocatedUnfairLock(initialState: false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(request: request, body: Self.readBody(request), at: Date())
        let handler = Self.state.withLock { s -> Handler? in
            s.recorded.append(recorded)
            return s.handler
        }
        deliver(handler?(recorded) ?? .failure(.notConnectedToInternet))
    }

    private func deliver(_ answer: Answer) {
        if stopped.withLock({ $0 }) { return }
        if case .delayed = answer {} else { Self.answered.withLock { $0 += 1 } }
        switch answer {
        case let .response(status, headers, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .redirect(to):
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/2", headerFields: ["Location": to])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: response)
            // Followed, the session stops this load and starts one for the new URL. Refused, the 302
            // is the answer.
            if stopped.withLock({ $0 }) { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case let .delayed(seconds, answer):
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.deliver(answer) }
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
