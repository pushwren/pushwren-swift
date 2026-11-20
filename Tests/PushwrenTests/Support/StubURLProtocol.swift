import Foundation
import os

/// Intercepts URLSession requests in tests: records each one and answers from a handler.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let request: URLRequest
        let body: Data
    }

    enum Answer: Sendable {
        case response(status: Int, headers: [String: String] = [:], body: Data = Data())
        case failure(URLError.Code)
    }

    typealias Handler = @Sendable (Recorded) -> Answer

    private static let state = OSAllocatedUnfairLock<(handler: Handler?, recorded: [Recorded])>(initialState: (nil, []))

    static func answer(with handler: @escaping Handler) {
        state.withLock { $0 = (handler, []) }
    }

    static var recorded: [Recorded] { state.withLock { $0.recorded } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(request: request, body: Self.readBody(request))
        let handler = Self.state.withLock { s -> Handler? in
            s.recorded.append(recorded)
            return s.handler
        }
        switch handler?(recorded) ?? .failure(.notConnectedToInternet) {
        case let .response(status, headers, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

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

extension StubURLProtocol.Answer {
    static func json(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> Self {
        .response(status: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: object))
    }
}
