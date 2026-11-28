# Changelog

## 0.6.0

Requires the Pushwren server's privacy switches (live with this release).

- **Choose when to register.** `Pushwren.configure(appKey:environment:registration:)` takes
  `.automatic` (the default, as before) or `.manual`. In manual mode a phone that isn't registered
  yet sends nothing and asks iOS for no token until the app calls `Pushwren.register()`; `setUserID`
  and tags set before then go out with the first registration. A registered phone keeps syncing at
  each launch in either mode.
- **A deleted phone stays deleted.** When the server answers `410 device_deleted`, the SDK forgets
  the device ID, user and tags and sends nothing, across relaunches, until `Pushwren.register()`,
  which registers it with a new device ID. A reinstall clears it. `Pushwren.deleteDevice()` now ends
  in the same state instead of registering again on the next sync. `Pushwren.diagnostics()` shows
  "Deleted on the server. Call Pushwren.register() to register again."
- **Analytics.** A tap is reported only when the push carries Pushwren's open marker (`_o`, sent
  when the app has open tracking on). `Pushwren.setAnalyticsEnabled(false)` stops this phone
  reporting taps and tells the server to ask it for no receipts. `Pushwren.opens` still gets every
  tap. `OpenedNotification.data` leaves out `_o`.

Moving from 0.5.x: change the package rule to Up to Next Minor Version from 0.6.0. If you adopt
`.manual` for a consent choice, call `Pushwren.deleteDevice()` for anyone who hasn't consented.
