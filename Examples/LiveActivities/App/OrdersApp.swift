import ActivityKit
import Pushwren
import SwiftUI

/// Your app's publishable key from the Pushwren portal (pk_live_…, or pk_dev_… for the dev API).
let pushwrenAppKey = "pk_live_REPLACE_WITH_YOUR_32_CHARACTER_KEY"

/// Remote start needs the key a start writes into the attributes; the type already has it.
extension OrderAttributes: PushwrenActivityAttributes {}

@main
struct OrdersApp: App {
    @UIApplicationDelegateAdaptor(PushwrenAppDelegate.self) var appDelegate

    init() {
        Pushwren.logLevel = .debug
        Pushwren.configure(appKey: pushwrenAppKey)
        if #available(iOS 17.2, *) {
            // Reports the push-to-start token, and tracks every OrderAttributes activity (started by a
            // push or by the app) under its pushwrenKey, including those running from an earlier launch.
            Pushwren.liveActivities.enableRemoteStart(for: OrderAttributes.self)
        } else {
            // Before iOS 17.2: track again the activities still running from an earlier launch.
            for activity in Activity<OrderAttributes>.activities {
                Pushwren.liveActivities.track(activity, key: activity.attributes.pushwrenKey)
            }
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
