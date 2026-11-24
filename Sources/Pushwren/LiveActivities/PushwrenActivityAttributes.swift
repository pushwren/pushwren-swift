#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit

/// An activity type your server can start with a push (iOS 17.2 and later). A remote start
/// carries no activity ID the app could look up, so Pushwren writes the start's key into the
/// attributes as `pushwrenKey`, and the app tracks the activity under it:
///
/// ```swift
/// struct OrderAttributes: PushwrenActivityAttributes {
///     struct ContentState: Codable, Hashable {
///         var status: String
///     }
///     var pushwrenKey: String  // stored, so the key in the push decodes into it
///     var orderNumber: String
/// }
/// ```
///
/// Declare `pushwrenKey` as a stored property under that name (no `CodingKeys` renaming it):
/// ActivityKit decodes the push's `attributes` into your type. When the app starts one of these
/// activities itself, set `pushwrenKey` to the key you want to update it by.
@available(iOS 16.1, *)
public protocol PushwrenActivityAttributes: ActivityAttributes {
    /// The key the activity is updated and ended by, such as "order-A1001": 1 to 64 letters,
    /// digits and _ . : -
    var pushwrenKey: String { get }
}

#endif
