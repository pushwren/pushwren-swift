# Live Activities sample

A small iPhone app with one Live Activity type, `OrderAttributes`, and its widget extension. Use it
to check Pushwren's three Live Activity mechanisms on a phone:

1. **Started by the app** (iOS 16.2 and later in this sample): the app starts an order activity and
   your server updates and ends it by its key, `order-A1001`.
2. **Started by your server** (iOS 17.2 and later): your server starts an activity with a push.
3. **Broadcast** (iOS 18 and later): your server sends one update to every device that follows a key.

This folder holds plain source files, not an Xcode project. The steps below build the project in a
few minutes.

## What you need

- Xcode 16 or later, and an iPhone on iOS 16.2 or later (17.2 for remote start, 18 for broadcast).
  Use a real device: that's where this check counts.
- An Apple Developer account. You'll pick your team in Xcode; its Team ID looks like `ABCDE12345`.
- A Pushwren app with an APNs key (`.p8`) uploaded and **Valid** for the environment you'll test.
  An Xcode debug build uses **sandbox**. You'll need the app's publishable key (`pk_live_…`) and a
  secret key (`sk_live_…`) for the server calls.

## Make the Xcode project

1. **Create the app.** Choose **File › New › Project › iOS › App**. Name it `Orders`, with Interface
   **SwiftUI** and Language **Swift**. Pick your team and a bundle identifier of your own, such as
   `com.example.orders`. In the target's **General** tab, set **Minimum Deployments** to iOS 16.2.
2. **Add Pushwren.** Choose **File › Add Package Dependencies…** and paste
   `https://github.com/pushwren/pushwren-swift`, or choose **Add Local…** and pick your checkout.
   Add the **Pushwren** product to the **Orders** target only.
3. **Add the app's sources.** Delete the generated `OrdersApp.swift` and `ContentView.swift`. Drag
   in `App/OrdersApp.swift`, `App/ContentView.swift` and `Shared/OrderAttributes.swift`, ticking
   the **Orders** target.
4. **Turn on push.** In the Orders target's **Signing & Capabilities** tab, click **+ Capability** and
   add **Push Notifications**.
5. **Allow Live Activities.** In the Orders target's **Info** tab, add the key
   `NSSupportsLiveActivities` (shown as "Supports Live Activities"), a Boolean set to **YES**.
6. **Add the widget extension.** Choose **File › New › Target › iOS › Widget Extension**:
   - Name it `OrdersWidget`.
   - Tick **Include Live Activity**. Untick **Include Control** and **Include Configuration App
     Intent**.
   - When Xcode offers to activate the new scheme, choose **Don't Activate**, so you keep running
     the app.
7. **Add the widget's sources.**
   - Delete the Swift files Xcode generated in the `OrdersWidget` folder.
   - Drag in `Widget/OrdersWidgetBundle.swift` and `Widget/OrderLiveActivity.swift`, ticking
     **OrdersWidget**.
   - Select `Shared/OrderAttributes.swift`. In the File inspector's **Target Membership**, tick
     **OrdersWidget** as well as Orders.
   - Set the OrdersWidget target's **Minimum Deployments** to iOS 16.2.
   - Don't add Pushwren to the widget: the app reports the tokens.
8. **Paste your publishable key** into `pushwrenAppKey` at the top of `OrdersApp.swift`.
9. **Turn on Broadcast** (only for mechanism 3). Xcode can't do this: on
   [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list), open
   **Certificates, Identifiers & Profiles › Identifiers**, select the app's App ID, and under **Push
   Notifications** turn on **Broadcast Capability**. Save.

Run the **Orders** scheme on your iPhone. Allow notifications if asked. The **This device** section
shows a device ID once the device has registered: tap **Copy device ID**, which you'll need for the
remote start. With `logLevel = .debug`, Console.app shows each report under the subsystem
`com.pushwren.sdk` (for example "Reported the OrderAttributes update token …1a2b3c4d for
order-A1001").

## Try it

The calls below use `curl` with your secret key. Never put a secret key in an app.

```sh
export PW=https://api.pushwren.com
export SK=sk_live_...
```

### 1. An activity the app starts

Tap **Start order A1001**. Pushwren reports the activity's update token under `order-A1001`. Then
update it:

```sh
curl -X PATCH "$PW/v1/live-activities/order-A1001" -H "Authorization: Bearer $SK" \
  -H 'Content-Type: application/json' \
  -d '{"contentState":{"status":"Preparing","etaMinutes":12}}'
```

And end it:

```sh
curl -X POST "$PW/v1/live-activities/order-A1001/end" -H "Authorization: Bearer $SK" \
  -H 'Content-Type: application/json' \
  -d '{"contentState":{"status":"Picked up","etaMinutes":0}}'
```

Each call answers `202`. `GET $PW/v1/live-activities/order-A1001` shows each device's last result:
`accepted` means Apple accepted the push, not that the phone has shown it. Apple also limits how
often high-priority updates reach a device.

Tapping **End every order here** ends the activity on the phone instead. Pushwren reports the end,
and the server stops sending to this device.

### 2. An activity your server starts (iOS 17.2+)

At launch, `enableRemoteStart(for: OrderAttributes.self)` reports the device's push-to-start
token. Start an activity on this device, using the device ID you copied:

```sh
curl -X POST "$PW/v1/live-activities" -H "Authorization: Bearer $SK" \
  -H 'Content-Type: application/json' \
  -d '{
    "key": "order-A1002",
    "attributesType": "OrderAttributes",
    "attributes": {"orderNumber": "A1002"},
    "contentState": {"status": "Received", "etaMinutes": 25},
    "target": {"deviceIds": ["dev_..."]},
    "alert": {"title": "Order A1002", "body": "We have your order."}
  }'
```

- `attributesType` is the Swift type's name, exactly as Pushwren reports it.
- Pushwren writes the key into the attributes as `pushwrenKey`, so the app tracks the new activity
  under `order-A1002` and reports its update token.

Update and end it with the same calls as in step 1, under `order-A1002`.

On iOS 18, Pushwren asks Apple for an update token on every remote start. Whether iOS 17.2 to 17.x
issues one is unverified. If `GET $PW/v1/live-activities/order-A1002` shows no device after the
start on a 17.x phone, updates can't reach it there; please note it.

### 3. Broadcast (iOS 18+)

Create the broadcast key. Pushwren makes an Apple channel in each environment where the app's APNs
key is valid:

```sh
curl -X POST "$PW/v1/live-activities/broadcasts" -H "Authorization: Bearer $SK" \
  -H 'Content-Type: application/json' -d '{"key":"broadcast-demo"}'
```

On the phone, tap **Follow broadcast-demo**. The app looks up the channel for its own environment
with `Pushwren.liveActivities.channel(for:)` and starts an activity on it. Then update every
follower with one call, and end it:

```sh
curl -X PATCH "$PW/v1/live-activities/broadcast-demo" -H "Authorization: Bearer $SK" \
  -H 'Content-Type: application/json' \
  -d '{"contentState":{"status":"Doors open","etaMinutes":0}}'
curl -X POST "$PW/v1/live-activities/broadcast-demo/end" -H "Authorization: Bearer $SK"
```

When you're done, delete the key, which deletes its Apple channels:

```sh
curl -X DELETE "$PW/v1/live-activities/broadcasts/broadcast-demo" -H "Authorization: Bearer $SK"
```

## If something doesn't work

- **The activity doesn't start:** check `NSSupportsLiveActivities` (step 5), and that Live
  Activities are on in **Settings › Orders**.
- **No token reports in Console:** the device must register first. `print(await
  Pushwren.diagnostics())` shows its state and the last error.
- **A report is dropped with `conflict`:** the key already belongs to another activity type, or it's
  a broadcast key. Use another key.
- **Creating the broadcast key fails with `broadcast_not_enabled`:** turn on Broadcast for the App
  ID (step 9).
