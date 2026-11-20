/// Whether the user lets the app show notifications, as the API records it per device.
public enum AuthorizationStatus: String, Sendable, Codable {
    case authorized, provisional, denied, notDetermined, ephemeral
}
