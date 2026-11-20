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
