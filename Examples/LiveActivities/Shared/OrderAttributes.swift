import ActivityKit

/// The sample's one Live Activity type, in both the app and the widget extension.
///
/// It is declared `ActivityAttributes` here, so the widget extension doesn't link Pushwren; the app
/// adds the `PushwrenActivityAttributes` conformance (OrdersApp.swift), which remote start needs.
/// Pushwren reports the type as "OrderAttributes", the Swift type's name: a remote start sends
/// exactly that as `attributesType`.
struct OrderAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var etaMinutes: Int
    }

    /// The key the activity is updated and ended by. A remote start writes it here, so keep it a
    /// stored property with this name.
    var pushwrenKey: String
    var orderNumber: String
}
