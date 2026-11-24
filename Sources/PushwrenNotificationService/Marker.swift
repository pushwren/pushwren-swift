extension PushwrenExtension {
    /// Found in a built extension's executable by the main Pushwren library, which then reports that
    /// the app ships this helper. `handle` uses it, so the linker never strips it.
    public static let markerString = "com.pushwren.notification-service.v1"
}
