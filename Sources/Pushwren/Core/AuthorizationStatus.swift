import UserNotifications

/// Whether the user lets the app show notifications, as the API records it per device.
public enum AuthorizationStatus: String, Sendable, Codable {
    case authorized, provisional, denied, notDetermined, ephemeral

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        #if os(iOS)
        case .ephemeral: self = .ephemeral
        #endif
        @unknown default: self = .notDetermined
        }
    }
}

extension AuthorizationStatus {
    /// The app's current notification permission.
    ///
    /// Nonisolated on purpose: `UNNotificationSettings` isn't `Sendable` in the Xcode 16 SDKs, so an
    /// actor that awaited `notificationSettings()` itself would fail to compile there. Only this
    /// `Sendable` enum crosses back to the caller.
    static func current() async -> AuthorizationStatus {
        AuthorizationStatus(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }
}
