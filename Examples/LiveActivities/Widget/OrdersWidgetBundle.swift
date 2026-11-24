import SwiftUI
import WidgetKit

/// The widget extension's entry point. It doesn't link Pushwren: the app reports the tokens.
@main
struct OrdersWidgetBundle: WidgetBundle {
    var body: some Widget {
        OrderLiveActivity()
    }
}
