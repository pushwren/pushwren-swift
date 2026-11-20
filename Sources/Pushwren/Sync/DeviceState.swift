import Foundation

/// What the device record should say. Fields fill in as they become known; nothing is sent
/// until there is a token and an environment.
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
            userId: userId,
            userIdSignature: userIdSignature,
            tags: tags,
            locale: locale,
            timezone: timezone,
            appVersion: appVersion,
            osVersion: osVersion,
            sdkVersion: sdkVersion,
            model: model
        )
    }
}

/// What survives a relaunch: the wanted state, the last registration the server accepted, and when.
struct PersistedState: Codable, Equatable, Sendable {
    var desired: DeviceState
    var lastSent: DevicePayload?
    var lastSyncAt: Date?

    init(desired: DeviceState, lastSent: DevicePayload? = nil, lastSyncAt: Date? = nil) {
        self.desired = desired
        self.lastSent = lastSent
        self.lastSyncAt = lastSyncAt
    }
}
