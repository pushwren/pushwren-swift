import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
/// The app delegate that forwards APNs callbacks to Pushwren, with no swizzling.
/// Use `@UIApplicationDelegateAdaptor(PushwrenAppDelegate.self)`, or subclass it for your own
/// handling (call super). It also becomes the notification center's delegate and shows
/// notifications that arrive while the app is open as banners.
open class PushwrenAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    open func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    open func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Pushwren.didRegister(deviceToken: deviceToken)
    }

    open func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Pushwren.didFailToRegister(error: error)
    }

    nonisolated open func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated open func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Pushwren.didReceive(response: response)
        completionHandler()
    }
}

#elseif canImport(AppKit)
/// The app delegate that forwards APNs callbacks to Pushwren, with no swizzling.
/// Use `@NSApplicationDelegateAdaptor(PushwrenAppDelegate.self)`, or subclass it for your own
/// handling (call super). It also becomes the notification center's delegate and shows
/// notifications that arrive while the app is open as banners.
open class PushwrenAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    open func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApplication.shared.registerForRemoteNotifications()
    }

    open func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Pushwren.didRegister(deviceToken: deviceToken)
    }

    open func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Pushwren.didFailToRegister(error: error)
    }

    nonisolated open func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated open func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Pushwren.didReceive(response: response)
        completionHandler()
    }
}
#endif
