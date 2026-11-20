import Foundation

/// What the device record should say. Fields fill in as they become known; nothing is sent
/// until there is a token and an environment. `userId`, `userIdSignature` and `tags` are the app's
/// own view: they are not in the registration, but go out as PATCH operations, and are applied
/// again in full when the server creates a new record for this device.
struct DeviceState: Codable, Equatable, Sendable {
    var token: String?
    var environment: ApsEnvironment?
    var platform: Platform
    var bundleId: String
    var authorizationStatus: AuthorizationStatus?
    var userId: String?
    var userIdSignature: String?
    var tags: [String] = []
    var locale: String?
    var timezone: String?
    var appVersion: String?
    var osVersion: String?
    var sdkVersion: String?
    var model: String?

    init(platform: Platform, bundleId: String, sdkVersion: String? = nil) {
        self.platform = platform
        self.bundleId = bundleId
        self.sdkVersion = sdkVersion
    }

    /// The registration to send, or nil while the token or environment is unknown.
    func payload() -> DevicePayload? {
        guard let token, let environment else { return nil }
        return DevicePayload(
            token: token,
            environment: environment,
            platform: platform,
            bundleId: bundleId,
            authorizationStatus: authorizationStatus,
            locale: locale,
            timezone: timezone,
            appVersion: appVersion,
            osVersion: osVersion,
            sdkVersion: sdkVersion,
            model: model
        )
    }
}

/// What survives a relaunch: the wanted state, the last registration the server accepted, when,
/// and on which API host, plus the tag and user changes not yet sent.
struct PersistedState: Codable, Equatable, Sendable {
    /// 2 since 0.2.0. Version 1 (0.1.x) had no pending changes and sent tags in every registration.
    var version = 2
    var desired: DeviceState
    var lastSent: DevicePayload?
    var lastSyncAt: Date?
    var lastSentHost: String?
    var pending = PendingChanges()

    init(desired: DeviceState, lastSent: DevicePayload? = nil, lastSyncAt: Date? = nil) {
        self.desired = desired
        self.lastSent = lastSent
        self.lastSyncAt = lastSyncAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, desired, lastSent, lastSyncAt, lastSentHost, pending
    }

    /// Reads version 1 files too: their tags and user already reached the server inside the
    /// registration, so nothing is pending.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        desired = try c.decode(DeviceState.self, forKey: .desired)
        lastSent = try c.decodeIfPresent(DevicePayload.self, forKey: .lastSent)
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastSentHost = try c.decodeIfPresent(String.self, forKey: .lastSentHost)
        pending = try c.decodeIfPresent(PendingChanges.self, forKey: .pending) ?? PendingChanges()
        version = 2
    }
}
