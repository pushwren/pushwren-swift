# Pushwren for Swift

Push notifications for Apple apps, without running your own APNs server. This package registers
your app's devices with [Pushwren](https://pushwren.com). Your server, or the Pushwren portal,
then sends to them by device, user or tag.

> **Alpha (0.x).** The API may change before 1.0.

## Requirements

- iOS 16, iPadOS 16, Mac Catalyst 16 or macOS 13 and later.
- Xcode 16 or later. The package uses Swift 6 and has no dependencies.
- An APNs auth key (`.p8`) uploaded to your app in the Pushwren portal, and the app's
  publishable key (`pk_live_…`) from the portal. New to APNs keys? See
  [Making an APNs key](https://docs.pushwren.com/guides/apns-key).

## Install

1. In Xcode, choose **File › Add Package Dependencies…**, paste
   `https://github.com/pushwren/pushwren-swift`, choose **Up to Next Minor Version** (while the SDK is
   0.x, a minor release may change its API), and add the **Pushwren** product to your app target.
2. Under **Signing & Capabilities**, add **Push Notifications**. This is required.
3. Also add **Background Modes** and tick **Remote notifications** if you'll send silent
   (background) pushes: without it they don't wake the app. Add both capabilities in **Signing &
   Capabilities**; setting `INFOPLIST_KEY_UIBackgroundModes` as a build setting has no effect.

If you use `Package.swift` instead of Xcode, add
`.package(url: "https://github.com/pushwren/pushwren-swift", .upToNextMinor(from: "0.5.0"))`.

## Use

Configure Pushwren with your publishable key, and use Pushwren's app delegate:

```swift
import Pushwren
import SwiftUI

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(PushwrenAppDelegate.self) var appDelegate

    init() {
        Pushwren.configure(appKey: "pk_live_...")
    }

    var body: some Scene { WindowGroup { ContentView() } }
}
```

On native macOS, use `@NSApplicationDelegateAdaptor(PushwrenAppDelegate.self)` instead. Then, where
they fit your app:

```swift
let status = try await Pushwren.requestPermission()  // ask to show alerts
Pushwren.setUserID("u_123")                          // after sign-in, and at every launch while signed in
Pushwren.clearUserID()                               // on sign-out
print(await Pushwren.diagnostics())                  // what Pushwren knows about this device
```

### Live Activities (iOS)

Your server updates, ends and starts Live Activities by a key of your own, such as `order-A1001`.
The app hands Pushwren the tokens Apple issues:

```swift
// After starting an activity (iOS 16.1+): its update token, each rotation, and its end.
let activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
Pushwren.liveActivities.track(activity, key: "order-A1001")

// At launch (iOS 17.2+): your server may start activities of this type with a push.
Pushwren.liveActivities.enableRemoteStart(for: OrderAttributes.self)

// A broadcast key your server created (iOS 18+): start an activity that follows it.
let channel = try await Pushwren.liveActivities.channel(for: "game-4521")
```

A type with remote start conforms to `PushwrenActivityAttributes`, a stored `pushwrenKey` the start
fills in. On a remote start, your server sends `attributesType` as the Swift type's name
(`"OrderAttributes"`), which is what Pushwren reports. A remotely started activity can be updated
only after the person taps **Allow** on Apple's "Allow Live Activities from *your app*?" prompt,
shown with it: iOS gives the app the activity's update token only then. [Examples/LiveActivities](Examples/LiveActivities)
is a sample app with a widget extension, and the Xcode steps.

### Images and delivery receipts (iOS)

A Notification Service Extension lets a push show an image, and confirms on the device that each
push arrived, which Pushwren shows as **Delivered**. In Xcode, add a **Notification Service
Extension** target to your app, add the **PushwrenNotificationService** product to that target (not
Pushwren), and make its class a subclass:

```swift
import PushwrenNotificationService

class NotificationService: PushwrenNotificationService {}
```

If your extension already does its own work, call `PushwrenExtension.handle(request, contentHandler:)`
from `didReceive` and the returned handle's `timeWillExpire()` from `serviceExtensionTimeWillExpire()`.
The app finds the helper in its extension at launch and tells Pushwren, which only then asks that
device for receipts. Delivered is a lower bound: a receipt can be lost on the way. See
[Images and delivery receipts](https://docs.pushwren.com/guides/images-and-receipts).

## Documentation

The docs at [docs.pushwren.com](https://docs.pushwren.com) cover the rest:

- [Quickstart](https://docs.pushwren.com/quickstart): from no account to a push on your phone, then
  sending from your server.
- [How Apple push works](https://docs.pushwren.com/how-push-works)
- [Making an APNs key](https://docs.pushwren.com/guides/apns-key)
- [Users and sign-out](https://docs.pushwren.com/guides/users)
- [If your app already has an app delegate](https://docs.pushwren.com/guides/app-delegate)
- [Identity verification](https://docs.pushwren.com/guides/identity-verification)
- [Silent pushes](https://docs.pushwren.com/guides/silent-pushes)
- [Live Activities](https://docs.pushwren.com/guides/live-activities)
- [Images and delivery receipts](https://docs.pushwren.com/guides/images-and-receipts)
- [Troubleshooting](https://docs.pushwren.com/guides/troubleshooting)
- [API reference](https://docs.pushwren.com/api) and [errors](https://docs.pushwren.com/errors)

## What it does

- Registers the device once, in the background, with the right APNs environment for the build:
  sandbox for Xcode debug builds, production for TestFlight and App Store builds.
- Keeps a device ID and secret in the Keychain, on this device only.
- Sends changes when they happen, plus a refresh at most once a week. It retries with backoff,
  honors `Retry-After`, and keeps pending changes across relaunches.
- Reports Live Activity tokens (update and push-to-start, again whenever Apple rotates one) and
  each activity's end through the same queue, so your server addresses activities by its own key.
  Live Activities are iOS and iPadOS only.
- Counts opens: a tap on a notification Pushwren sent is reported once, even across relaunches.
- Tells Pushwren whether the app ships its Notification Service Extension helper, so receipts are
  asked only of devices that can send them; the helper attaches images and posts the receipts.
- Sends tag and user-ID changes as changes, not as a full list, so tags your server adds with
  `PATCH /v1/devices/{id}` stay when the app adds its own. For the user ID, the last change wins.
- Ships a privacy manifest. There is no tracking and no IDFA.

## Privacy

The package's `PrivacyInfo.xcprivacy` declares two data types, both **linked to the user**, not used
for tracking, and used for **app functionality**:
- **Device ID**: the device ID and push token Pushwren keeps for this install;
- **User ID**: the ID you pass to `setUserID`.

Declare the same in your App Store privacy answers. Linking the package adds the manifest to every
build of that target, even one that never calls `configure`. Registrations also send the device
model, OS and app version, locale, time zone and notification permission, and taps send an
`opened` event. With the extension helper, a push that asks for a receipt sends one when it
arrives. Pushwren uses them to deliver and count your pushes.

## License

MIT
