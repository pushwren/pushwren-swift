import Foundation

/// The body of PUT /v1/devices/{deviceId}, field for field the server's RegisterDevice
/// (packages/shared/src/api/devices.ts). Absent fields are left out of the JSON.
struct DevicePayload: Codable, Equatable, Sendable {
    var token: String
    var environment: ApsEnvironment
    var platform: Platform
    var bundleId: String
    var authorizationStatus: AuthorizationStatus?
    var userId: String?
    var userIdSignature: String?
    var tags: [String]
    var locale: String?
    var timezone: String?
    var appVersion: String?
    var osVersion: String?
    var sdkVersion: String?
    var model: String?

    init(
        token: String,
        environment: ApsEnvironment,
        platform: Platform,
        bundleId: String,
        authorizationStatus: AuthorizationStatus? = nil,
        userId: String? = nil,
        userIdSignature: String? = nil,
        tags: [String] = [],
        locale: String? = nil,
        timezone: String? = nil,
        appVersion: String? = nil,
        osVersion: String? = nil,
        sdkVersion: String? = nil,
        model: String? = nil
    ) {
        self.token = token
        self.environment = environment
        self.platform = platform
        self.bundleId = bundleId
        self.authorizationStatus = authorizationStatus
        self.userId = userId
        self.userIdSignature = userIdSignature
        // Sorted, so the same set of tags always compares and encodes the same.
        self.tags = tags.sorted()
        self.locale = locale
        self.timezone = timezone
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.sdkVersion = sdkVersion
        self.model = model
    }
}

enum APIError: Error, Equatable, Sendable {
    /// 403: the device secret is missing or wrong.
    case forbidden
    /// 401: the app key is unknown or revoked.
    case invalidKey
    /// Any other 4xx: the request itself is wrong, and sending it again won't help.
    case rejected(code: String, message: String)
    /// 429: wait this many seconds.
    case retryAfter(TimeInterval)
    /// 5xx, timeouts, no network: try again later.
    case transient
}

/// When to try again after a failure. nil means don't: the request needs to change first.
enum RetryPolicy {
    static let maxDelay: TimeInterval = 300

    static func delay(attempt: Int, error: APIError, jitter: Double = Double.random(in: 0.5...1.0)) -> TimeInterval? {
        switch error {
        case .retryAfter(let seconds): return seconds
        case .transient: return min(maxDelay, pow(2, Double(min(attempt, 30)))) * jitter
        case .forbidden, .invalidKey, .rejected: return nil
        }
    }
}

/// The Pushwren device API, as the SDK uses it.
struct APIClient: Sendable {
    let key: AppKey
    let session: URLSession

    init(key: AppKey, session: URLSession = .shared) {
        self.key = key
        self.session = session
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    /// Registers or updates the device. Returns the device secret when the server created the
    /// device (201), nil when it updated it.
    func putDevice(_ deviceID: String, _ payload: DevicePayload, secret: String?) async throws(APIError) -> String? {
        let body: Data
        do { body = try Self.encoder.encode(payload) } catch { throw .rejected(code: "encoding", message: "\(error)") }
        let (status, data) = try await send("PUT", deviceID, body: body, secret: secret)
        guard status == 201 else { return nil }
        struct Created: Decodable { let deviceSecret: String }
        return (try? JSONDecoder().decode(Created.self, from: data))?.deviceSecret
    }

    /// Removes the device. A device the server no longer has counts as removed.
    func deleteDevice(_ deviceID: String, secret: String) async throws(APIError) {
        do {
            _ = try await send("DELETE", deviceID, body: nil, secret: secret)
        } catch .rejected(let code, _) where code == "not_found" {
            return
        }
    }

    private func send(_ method: String, _ deviceID: String, body: Data?, secret: String?) async throws(APIError) -> (Int, Data) {
        var request = URLRequest(url: key.apiBaseURL.appendingPathComponent("v1/devices/\(deviceID)"), timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(key.raw)", forHTTPHeaderField: "Authorization")
        request.setValue("pushwren-swift/\(SDK.version)", forHTTPHeaderField: "User-Agent")
        if let secret { request.setValue(secret, forHTTPHeaderField: "X-Device-Secret") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .transient
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return (status, data)
        case 401:
            throw .invalidKey
        case 403:
            throw .forbidden
        case 404:
            throw .rejected(code: "not_found", message: "not found")
        case 429:
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            throw .retryAfter(header.flatMap(TimeInterval.init) ?? 60)
        case 400..<500:
            struct Failure: Decodable {
                struct Body: Decodable { let code: String; let message: String }
                let error: Body
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw .rejected(code: failure?.error.code ?? "http_\(status)", message: failure?.error.message ?? "")
        default:
            throw .transient
        }
    }
}
