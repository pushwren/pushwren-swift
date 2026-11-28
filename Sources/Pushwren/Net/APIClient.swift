import Foundation

/// The body of PUT /v1/devices/{deviceId}: the server's RegisterDevice
/// (packages/shared/src/api/devices.ts) without tags and user ID, which go out as PATCH
/// operations (PendingChanges) so the server's own changes to them survive. Absent fields are
/// left out of the JSON.
struct DevicePayload: Codable, Equatable, Sendable {
    var token: String
    var environment: ApsEnvironment
    var platform: Platform
    var bundleId: String
    var authorizationStatus: AuthorizationStatus?
    var locale: String?
    var timezone: String?
    var appVersion: String?
    var osVersion: String?
    var sdkVersion: String?
    var model: String?
    var serviceExtension: Bool?
    /// false when the person switched analytics off (0.6.0); left out otherwise.
    var analytics: Bool?

    init(
        token: String,
        environment: ApsEnvironment,
        platform: Platform,
        bundleId: String,
        authorizationStatus: AuthorizationStatus? = nil,
        locale: String? = nil,
        timezone: String? = nil,
        appVersion: String? = nil,
        osVersion: String? = nil,
        sdkVersion: String? = nil,
        model: String? = nil,
        serviceExtension: Bool? = nil,
        analytics: Bool? = nil
    ) {
        self.token = token
        self.environment = environment
        self.platform = platform
        self.bundleId = bundleId
        self.authorizationStatus = authorizationStatus
        self.locale = locale
        self.timezone = timezone
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.sdkVersion = sdkVersion
        self.model = model
        self.serviceExtension = serviceExtension
        self.analytics = analytics
    }
}

/// A registration's JSON: the payload's fields, plus an empty tag list when asked.
struct RegisterBody: Encodable {
    let payload: DevicePayload
    let clearTags: Bool

    private enum Keys: String, CodingKey { case tags }

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        if clearTags {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode([String](), forKey: .tags)
        }
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
    /// 410 `device_deleted` (0.6.0): the server deleted this device ID and refuses it for good.
    case deleted
}

/// When to try again after a failure. nil means don't: the request needs to change first.
enum RetryPolicy {
    static let maxDelay: TimeInterval = 300

    static func delay(attempt: Int, error: APIError, jitter: Double = Double.random(in: 0.5...1.0)) -> TimeInterval? {
        switch error {
        case .retryAfter(let seconds): return seconds
        case .transient: return min(maxDelay, pow(2, Double(min(attempt, 30)))) * jitter
        case .forbidden, .invalidKey, .rejected, .deleted: return nil
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
    /// device (201), nil when it updated it. `clearTags` sends `"tags": []`, which replaces the
    /// server's tags with none: after a reinstall, so the old install's tags don't linger.
    func putDevice(_ deviceID: String, _ payload: DevicePayload, secret: String?, clearTags: Bool = false) async throws(APIError) -> String? {
        let body: Data
        do { body = try Self.encoder.encode(RegisterBody(payload: payload, clearTags: clearTags)) } catch { throw .rejected(code: "encoding", message: "\(error)") }
        let (status, data) = try await send("PUT", "v1/devices/\(deviceID)", body: body, secret: secret)
        guard status == 201 else { return nil }
        struct Created: Decodable { let deviceSecret: String }
        return (try? JSONDecoder().decode(Created.self, from: data))?.deviceSecret
    }

    /// Applies tag and user-ID changes to the device the secret belongs to.
    func patchDevice(_ deviceID: String, _ patch: DevicePatch, secret: String) async throws(APIError) {
        let body: Data
        do { body = try Self.encoder.encode(patch) } catch { throw .rejected(code: "encoding", message: "\(error)") }
        _ = try await send("PATCH", "v1/devices/\(deviceID)", body: body, secret: secret)
    }

    /// Reports that the user opened a notification on this device. `receiptRequested`: the push
    /// asked for a delivery receipt (it carried `_r`), so the open also counts it as delivered.
    func postEvent(deviceID: String, notificationID: String, receiptRequested: Bool = false, secret: String) async throws(APIError) {
        struct Event: Encodable {
            let type = "opened"
            let deviceId: String
            let notificationId: String
            /// true or left out.
            let receiptRequested: Bool?
        }
        let event = Event(deviceId: deviceID, notificationId: notificationID, receiptRequested: receiptRequested ? true : nil)
        let body: Data
        do { body = try Self.encoder.encode(event) } catch { throw .rejected(code: "encoding", message: "\(error)") }
        _ = try await send("POST", "v1/events", body: body, secret: secret)
    }

    /// Removes the device. A device the server no longer has counts as removed.
    func deleteDevice(_ deviceID: String, secret: String) async throws(APIError) {
        do {
            _ = try await send("DELETE", "v1/devices/\(deviceID)", body: nil, secret: secret)
        } catch .rejected(let code, _) where code == "not_found" {
            return
        } catch .deleted {
            // Deleted already (the server answers 204 for a deleted ID; an older one may not).
            return
        }
    }

    // MARK: Live Activities

    /// Puts an activity's update token under its key, joining the key's activity or starting an app
    /// one. A rotated token replaces the device's old one. 409 `conflict` when the key is a broadcast
    /// key or another type's activity.
    func putActivityToken(_ deviceID: String, key: String, token: String, attributesType: String, secret: String) async throws(APIError) {
        struct Body: Encodable { let token: String; let attributesType: String }
        let body: Data
        do { body = try Self.encoder.encode(Body(token: token, attributesType: attributesType)) } catch { throw .rejected(code: "encoding", message: "\(error)") }
        _ = try await send("PUT", "v1/devices/\(deviceID)/live-activities/\(Self.segment(key))", body: body, secret: secret)
    }

    /// Takes the device off the key's activity. 204 also when it wasn't on it.
    func deleteActivityToken(_ deviceID: String, key: String, secret: String) async throws(APIError) {
        _ = try await send("DELETE", "v1/devices/\(deviceID)/live-activities/\(Self.segment(key))", body: nil, secret: secret)
    }

    /// Puts the device's push-to-start token for an activity type.
    func putStartToken(_ deviceID: String, attributesType: String, token: String, secret: String) async throws(APIError) {
        struct Body: Encodable { let token: String }
        let body: Data
        do { body = try Self.encoder.encode(Body(token: token)) } catch { throw .rejected(code: "encoding", message: "\(error)") }
        _ = try await send("PUT", "v1/devices/\(deviceID)/start-tokens/\(Self.segment(attributesType))", body: body, secret: secret)
    }

    /// Sends one queued Live Activity report.
    func send(_ report: ActivityReport, deviceID: String, secret: String) async throws(APIError) {
        switch report {
        case let .token(key, token, type):
            try await putActivityToken(deviceID, key: key, token: token, attributesType: type, secret: secret)
        case let .ended(key):
            try await deleteActivityToken(deviceID, key: key, secret: secret)
        case let .startToken(type, token):
            try await putStartToken(deviceID, attributesType: type, token: token, secret: secret)
        }
    }

    /// The broadcast channel ID of the key in the device's own APNs environment. Never creates one:
    /// 404 when there is none.
    func liveActivityChannel(key: String, deviceID: String, secret: String) async throws(APIError) -> String {
        let (_, data) = try await send("GET", "v1/live-activities/\(Self.segment(key))/channel?deviceId=\(Self.segment(deviceID))", body: nil, secret: secret)
        struct Found: Decodable { let channelId: String }
        guard let found = try? JSONDecoder().decode(Found.self, from: data) else { throw .transient }
        return found.channelId
    }

    /// Unreserved characters only (RFC 3986): letters, digits and - . _ ~
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A key or an activity type as one percent-encoded path segment.
    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Retry-After in seconds, kept between 1 s and an hour. A missing, negative or non-numeric
    /// value means a minute; NaN or infinity would otherwise crash the wait.
    static func retryAfter(_ header: String?) -> TimeInterval {
        guard let value = header.flatMap(TimeInterval.init), value.isFinite, value >= 0 else { return 60 }
        return min(max(value, 1), 3600)
    }

    private func send(_ method: String, _ path: String, body: Data?, secret: String?) async throws(APIError) -> (Int, Data) {
        // `path` is percent-encoded already: appending it as a path component would encode it again.
        guard let url = URL(string: key.apiBaseURL.absoluteString + "/" + path) else { throw .rejected(code: "encoding", message: path) }
        var request = URLRequest(url: url, timeoutInterval: 15)
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
            // "forbidden" means the device secret is missing or wrong. Any other code is about the
            // request (say invalid_user_signature, with identity verification on): a rejection, so
            // the device keeps its identity.
            struct Failure: Decodable {
                struct Body: Decodable { let code: String; let message: String }
                let error: Body
            }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data), failure.error.code != "forbidden" {
                throw .rejected(code: failure.error.code, message: failure.error.message)
            }
            throw .forbidden
        case 404:
            throw .rejected(code: "not_found", message: "not found")
        case 410:
            struct Failure: Decodable {
                struct Body: Decodable { let code: String; let message: String }
                let error: Body
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            if failure?.error.code == "device_deleted" { throw .deleted }
            throw .rejected(code: failure?.error.code ?? "http_410", message: failure?.error.message ?? "")
        case 429:
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            throw .retryAfter(Self.retryAfter(header))
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
