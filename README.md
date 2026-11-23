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
   `https://github.com/pushwren/pushwren-swift`, choose **Up to Next Minor Version** (while the SDK is
   0.x, a minor release may change its API), and add the **Pushwren** product to your app target.
2. Under **Signing & Capabilities**, add **Push Notifications**. This is required.
3. Also add **Background Modes** and tick **Remote notifications** if you'll send silent
   (background) pushes: without it they don't wake the app. Add both capabilities in **Signing &
   Capabilities**; setting `INFOPLIST_KEY_UIBackgroundModes` as a build setting has no effect.

If you use `Package.swift` instead of Xcode, add
`.package(url: "https://github.com/pushwren/pushwren-swift", .upToNextMinor(from: "0.3.0"))`.

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

`configure` registers the device with APNs straight away, without a permission prompt: the token
needs no permission. `PushwrenAppDelegate` also becomes the notification center's delegate. If only
some users or builds should get push, call `configure` only for them, and see
[If your app already has an app delegate](#if-your-app-already-has-an-app-delegate).

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

- **`requestPermission()`** returns an `AuthorizationStatus`: `.authorized`, `.provisional`,
  `.denied`, `.notDetermined` or `.ephemeral`. A user who says no gets `.denied`, not an error; it
  throws only if the system can't ask. The device stays registered either way, and the portal shows
  its permission. Pass `provisional: true` to deliver quietly without a prompt.
- **`opened.data`** is your push's `data` as `[String: Any]`; `opened.notificationID` and
  `opened.actionIdentifier` come with it.
- **A tap that launches the app** is kept until something reads `Pushwren.opens`. Start listening
  early, such as in a `.task` on your root view, and hold the route until your data has loaded.

### Users

Sending to `"userIds": ["u_123"]` reaches every device where the app called
`Pushwren.setUserID("u_123")`, so set it after sign-in, and at every launch while someone is signed
in. A reinstalled app starts with no user on the server even if your sign-in survived in the
Keychain; the call at launch links it again, and costs nothing when nothing changed.

- Use an opaque user ID, such as your database's ID for the user, not an email address or a phone
  number.
- Call `clearUserID()` on sign-out. It goes out at once, even if a retry is waiting. Tags stay:
  remove the ones that belonged to the user with `removeTags`.
- Setting the same user ID again sends nothing until the next launch, so calling it on every
  refresh is fine.
- A reinstalled app starts with no user and no tags on the server, even though it keeps its device
  ID: set them again at launch.
- When a user deletes their account, call `await Pushwren.deleteDevice()`. It removes the device
  record with its user and tags; the device registers again, as a new device with no user, the next
  time the app syncs. It returns `false` if Pushwren couldn't be reached.

### Identity verification

With identity verification on (portal: **Settings › Identity verification**), a user ID the app sets
must be signed by your server, so a modified app can't claim someone else's pushes. It's off until
you turn it on. Your server signs the user ID with the app's identity secret: HMAC-SHA256, as 64 hex
characters. The app passes it along:

```swift
Pushwren.setUserID("u_123", signature: signatureFromYourServer)
```

A missing or wrong signature is refused: the device keeps its record without the user, and
`diagnostics()` shows `invalid_user_signature`. Clearing the user, and your server's own calls with
a secret key, need no signature.

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

### Silent pushes

Pushwren doesn't handle silent pushes for you. With **Remote notifications** ticked under
Background Modes, add the handler to your delegate (a `PushwrenAppDelegate` subclass works):

```swift
func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any]
) async -> UIBackgroundFetchResult {
    // Refresh your data here, then:
    return .newData
}
```

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
permission, API host, the last sync and the last error, including a change the server refused.

The SDK's own messages ("Registered device…", dropped changes, errors) go to the unified log, which
Xcode shows only for apps it launched. For an app started from the home screen:
- **iPhone:** open Console on your Mac, select the connected iPhone, start streaming, and search for
  `subsystem:com.pushwren.sdk`.
- **Simulator:**

```bash
xcrun simctl spawn booted log stream --predicate 'subsystem == "com.pushwren.sdk"' --level info
```

| What you see | Likely cause |
| --- | --- |
| The log says registering failed: `no valid "aps-environment" entitlement string found` | The **Push Notifications** capability is missing, or the provisioning profile predates it. Add it and rebuild. |
| The build fails: `Provisioning profile … doesn't include the aps-environment entitlement` | The profile was made before you added Push Notifications. With automatic signing, Xcode makes a new one; from the command line, build with `-allowProvisioningUpdates` while signed in to Xcode. |
| No token, and the device never appears in the portal | Check `diagnostics()` for a registration error. On some iOS versions the token waits for the user to allow notifications. Simulators register only on some Macs, so try a real device. |
| The portal shows the push as `accepted`, but nothing appeared | Apple accepted it but doesn't confirm display. Check the device's environment and last-seen time in the portal, and that notifications are allowed. We've seen one case we couldn't explain; later pushes arrived. |
| `invalid_user_signature` in `diagnostics()` | Identity verification is on and the user ID had no valid signature. See [Identity verification](#identity-verification). |
| `Pushwren.configure needs a publishable key` in the log | The key isn't a `pk_…` key. Never ship a secret key (`sk_…`) in an app. |
| The device is registered, but pushes fail with `BadDeviceToken` | The build and the key's environment don't match. Xcode debug builds are **sandbox**; TestFlight and App Store builds are **production**. The portal's notification detail explains each failure. |
| Pushes arrive, but taps aren't counted or `Pushwren.opens` is silent | Something else is the notification center's delegate, and it doesn't forward `Pushwren.didReceive(response:)`. |
| Nothing shows while the app is open | That's iOS's default. `PushwrenAppDelegate` shows a banner; your own delegate needs `willPresent` (above). |

Pushwren writes errors and info to the unified log under the subsystem `com.pushwren.sdk`. Set
`Pushwren.logLevel` to `.error` for less, or `.off`.

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

## Privacy

The package's `PrivacyInfo.xcprivacy` declares two data types, both **linked to the user**, not used
for tracking, and used for **app functionality**:
- **Device ID**: the device ID and push token Pushwren keeps for this install;
- **User ID**: the ID you pass to `setUserID`.

Declare the same in your App Store privacy answers. Linking the package adds the manifest to every
build of that target, even one that never calls `configure`. Registrations also send the device
model, OS and app version, locale, time zone and notification permission, and taps send an
`opened` event; Pushwren uses them to deliver and count your pushes.

## License

MIT
