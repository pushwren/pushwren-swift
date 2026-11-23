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
  [Making an APNs key](docs/apns-key.md).

## Install

1. In Xcode, choose **File › Add Package Dependencies…**, paste
   `https://github.com/pushwren/pushwren-swift`, and add the **Pushwren** product to your app target.
2. Under **Signing & Capabilities**, add **Push Notifications**. This is required.
3. Also add **Background Modes** and tick **Remote notifications**. This is recommended:
   - With it, iOS issues the device token at first launch, so the device is registered before you
     ask for permission, and silent (background) pushes work.
   - Without it, current iOS versions issue the token only after the user allows notifications.
     Pushwren registers the device then, and silent pushes don't wake the app.

If you use `Package.swift` instead of Xcode, add
`.package(url: "https://github.com/pushwren/pushwren-swift", from: "0.2.1")`.

## Use

It takes two lines: configure Pushwren with your publishable key, and use Pushwren's app delegate.

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

Then call these wherever they fit your UI:

```swift
let status = try await Pushwren.requestPermission()  // ask to show alerts
Pushwren.setUserID("u_123")                          // after sign-in
Pushwren.clearUserID()                               // on sign-out
Pushwren.addTags(["pro"])
print(await Pushwren.diagnostics())                  // what Pushwren knows about this device

// Deep links: every tap, including the one that launched the app.
for await opened in Pushwren.opens {
    router.handle(opened.data)
}
```

Use an opaque user ID, such as your database's ID for the user, not an email address or a phone
number.

## If your app already has an app delegate

`PushwrenAppDelegate` does three things:
- forwards the device token to Pushwren;
- becomes the notification center's delegate, so taps are counted and appear on `Pushwren.opens`;
- shows notifications that arrive while the app is open as banners.

You can keep your own delegate in either of two ways.

**Subclass it** (easiest). Override what you need and call `super`:

```swift
final class AppDelegate: PushwrenAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
        // Your own launch setup.
        return result
    }
}

// In your App: @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
```

**Or forward the calls yourself.** You still call `Pushwren.configure` at launch, which asks for
the device token for you. The SDK never swizzles, so every forward below matters:

```swift
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Pushwren.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Pushwren.didFailToRegister(error: error)
    }

    // Without this, taps aren't counted as opens and never reach Pushwren.opens.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Pushwren.didReceive(response: response)
        completionHandler()
    }

    // Optional: show notifications while the app is open. Without it, iOS shows nothing in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
```

Only one object can be the notification center's delegate. If another library sets it after
you, Pushwren stops seeing taps.

## Sending from your server

Use a **secret key** (`sk_live_…`), made in the portal under **Settings › API keys**. A secret key
can send to every one of your users, so keep it on your server and never put it in an app.

```bash
curl https://api.pushwren.com/v1/notifications \
  -H "Authorization: Bearer $PUSHWREN_SECRET_KEY" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: order-A1001-shipped" \
  -d '{
        "target": { "userIds": ["u_123"] },
        "alert": { "title": "Order shipped", "body": "Your order A1001 is on its way." },
        "data": { "orderId": "A1001" }
      }'
```

The answer is `202 Accepted` with `{ "id": "ntf_…", "status": "queued" }`.

- **`target`** is exactly one of these:
  - `{ "deviceIds": [...] }` or `{ "userIds": [...] }`, up to 1,000 each;
  - `{ "tags": [...] }`, up to 10, which matches devices with any of them;
  - `{ "all": true }`;
  - `{ "testDevices": true }`, for the devices you marked as test devices in the portal.
- **`data`** keys arrive beside `aps` in the payload, and as `opened.data` in the app.
- **A silent push** sets `"options": { "pushType": "background" }`, with no `alert`, `badge` or `sound`.
- **`sendAt`** (ISO 8601, up to 30 days ahead) schedules the send. `DELETE /v1/notifications/{id}`
  cancels it before then.
- **`GET /v1/notifications/{id}`** returns its status and counts. `accepted` means Apple accepted the
  push; Apple doesn't confirm that the device showed it.
- **`Idempotency-Key`** is optional. Repeating a request with the same key within 24 hours sends
  once, so retry connection errors and `5xx` answers with the same key.
- **Errors** look like `{ "error": { "code", "message" } }`. The message names the field or
  explains the problem.

## When something doesn't work

Start with `print(await Pushwren.diagnostics())`. It shows the device ID, token, environment,
permission, API host and the last error.

| What you see | Likely cause |
| --- | --- |
| The log says registering failed: `no valid "aps-environment" entitlement string found` | The **Push Notifications** capability is missing, or the provisioning profile predates it. Add it and rebuild. |
| No token, and the device never appears in the portal | Without **Remote notifications** under Background Modes, there's no token until the user allows notifications. Otherwise, try a real device: simulators register only on some Macs. |
| `Pushwren.configure needs a publishable key` in the log | The key isn't a `pk_…` key. Never ship a secret key (`sk_…`) in an app. |
| The device is registered, but pushes fail with `BadDeviceToken` | The build and the key's environment don't match. Xcode debug builds are **sandbox**; TestFlight and App Store builds are **production**. The portal's notification detail explains each failure. |
| Pushes arrive, but taps aren't counted or `Pushwren.opens` is silent | Something else is the notification center's delegate, and it doesn't forward `Pushwren.didReceive(response:)`. |
| Nothing shows while the app is open | That's iOS's default. `PushwrenAppDelegate` shows a banner; your own delegate needs `willPresent` (above). |

Pushwren writes to the unified log under the subsystem `com.pushwren.sdk`. Set
`Pushwren.logLevel` for more detail.

## What it does

- Registers the device once, in the background, with the right APNs environment for the build:
  sandbox for Xcode debug builds, production for TestFlight and App Store builds.
- Keeps a device ID and secret in the Keychain, on this device only.
- Sends changes when they happen, plus a refresh at most once a week. It retries with backoff,
  honors `Retry-After`, and keeps pending changes across relaunches.
- Counts opens: a tap on a notification Pushwren sent is reported once, even across relaunches.
- Sends tag and user-ID changes as changes, not as a full list, so tags your server adds with
  `PATCH /v1/devices/{id}` stay when the app adds its own. For the user ID, the last change wins.
- Ships a privacy manifest. There is no tracking and no IDFA.

## License

MIT
