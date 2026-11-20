# Pushwren for Swift

Push notifications for Apple apps, without running your own APNs server. This package registers
your app's devices with [Pushwren](https://pushwren.com). Your server, or the Pushwren portal,
then sends to them by device, user or tag.

> **Alpha (0.x).** The API may change before 1.0.

## Requirements

- iOS 16, iPadOS 16, Mac Catalyst 16 or macOS 13 and later.
- Xcode 16 or later. The package uses Swift 6 and has no dependencies.

## Install

1. In Xcode, choose **File › Add Package Dependencies…**, paste
   `https://github.com/pushwren/pushwren-swift`, and add the **Pushwren** product to your app target.
2. Under **Signing & Capabilities**, add **Push Notifications**, then add **Background Modes**
   and tick **Remote notifications**.

   With Remote notifications on, iOS issues the device token at first launch, so the device is
   registered before you ask for permission, and silent pushes work. Without it, current iOS
   versions issue the token only once the user allows notifications, and Pushwren registers the
   device then.

With `Package.swift`, add `.package(url: "https://github.com/pushwren/pushwren-swift", from: "0.1.0")`.

## Use

Two lines: configure with your publishable key, and let Pushwren be your app delegate.

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

On native macOS, use `@NSApplicationDelegateAdaptor(PushwrenAppDelegate.self)` instead.

Then, wherever it fits your UI:

```swift
let status = try await Pushwren.requestPermission()  // ask to show alerts
Pushwren.setUserID("u_123")                          // after sign-in
Pushwren.clearUserID()                               // on sign-out
Pushwren.addTags(["pro"])
print(await Pushwren.diagnostics())                  // what Pushwren knows about this device
```

Apps that already have an app delegate can skip the adaptor and forward
`Pushwren.didRegister(deviceToken:)`, `Pushwren.didFailToRegister(error:)` and
`Pushwren.didReceive(response:)` instead. The SDK never swizzles.

## What it does

- Registers the device once, in the background, with the right APNs environment for the build:
  sandbox for Xcode debug builds, production for TestFlight and App Store builds.
- Keeps a device ID and secret in the Keychain, on this device only.
- Sends changes when they happen, plus a refresh at most once a week. It retries with backoff and
  keeps pending changes across relaunches.
- Sends tag and user-ID changes as changes, not as a full list, so tags your server adds with
  `PATCH /v1/devices/{id}` stay when the app adds its own. For the user ID, the last change wins.
- Ships a privacy manifest. There is no tracking and no IDFA.

## License

MIT
