# Making an APNs key

Pushwren sends your notifications through Apple Push Notification service (APNs), and Apple only
accepts them when they're signed with a key from your Apple Developer account. This guide takes you
from no key to a key uploaded to Pushwren. It takes about five minutes, and you do it once: one key
can cover every app on your team.

You'll come away with three things: a `.p8` file, its **Key ID**, and your **Team ID**.

## Before you start

- A Pushwren account, with your app created in the portal.
- A paid Apple Developer Program membership.
- The **Account Holder** or **Admin** role on that team. Other roles can't create keys.

Everything on Apple's side happens at
[developer.apple.com/account](https://developer.apple.com/account), under **Certificates,
Identifiers & Profiles**.

## 1. Find your Team ID

Open [developer.apple.com/account](https://developer.apple.com/account) and scroll to
**Membership details**. Your **Team ID** is a 10-character code such as `ABCDE12345`. Keep it handy;
Pushwren asks for it with the key.

<!-- verify: Team ID label and location on the account page -->
<!-- screenshot: Membership details, Team ID covered -->

## 2. Turn on Push Notifications for your app

Your app's App ID has to allow push.

**The easy way, in Xcode:** open your target, go to **Signing & Capabilities**, click
**+ Capability** and add **Push Notifications**. With **Automatically manage signing** on, Xcode
turns push on for the App ID for you. You need this capability in the app anyway, so do it now.

**Or on the website:** in Certificates, Identifiers & Profiles, click **Identifiers**, select your
app's App ID, click **Edit**, tick **Push Notifications**, and click **Save** (and **Confirm** if
Apple warns about changing it).

You don't need a push certificate. Keys replace certificates, and Pushwren uses keys only.

<!-- verify: automatic signing turns on Push Notifications for the App ID -->
<!-- screenshot: the App ID with Push Notifications ticked -->

## 3. Create the key

1. In Certificates, Identifiers & Profiles, click **Keys** in the sidebar, then the **+** button.
2. Under **Key Name**, enter a name you'll recognize later, such as `Pushwren`.
3. Tick **Apple Push Notifications service (APNs)** and click **Configure** next to it.
4. Choose the options:
   - **Environment: Sandbox & Production.** Builds you run from Xcode use the sandbox; TestFlight
     and App Store builds use production. A key for both works for every build. A sandbox-only key
     fails for TestFlight and App Store builds, and a production-only key fails for Xcode builds.
   - **Key type: Team Scoped.** It covers every app on your team, now and later. A **Topic
     Specific** key covers only the apps you pick, and must include your app's bundle ID.
5. Click **Save**, then **Continue**, review, and click **Register** (or **Confirm**).

<!-- verify: exact labels for the environment choice, the key type, and the final button -->
<!-- screenshot: the key name and APNs ticked -->
<!-- screenshot: Configure, with both choices -->

## 4. Download the key

Click **Download**. Apple saves a file named `AuthKey_<KeyID>.p8` to your Downloads folder.

**You can download a key only once.** Keep the file somewhere safe, such as your password manager.
Never put it in your app or commit it to a repository: anyone with the file can send notifications as
your apps. If you lose it, revoke the key and make a new one.

The **Key ID** is the 10 characters in the file name (`AuthKey_ABC123DEFG.p8` has the Key ID
`ABC123DEFG`). It's also shown under the key's name in **Keys**.

<!-- screenshot: the download page -->

## 5. Upload it to Pushwren

In the [Pushwren portal](https://app.pushwren.com), open your app's setup (or **Settings → APNs**
later):

1. Choose the `.p8` file. Pushwren fills in the **Key ID** from its name.
2. Enter your **Team ID** from step 1.
3. Click **Upload key**.

Pushwren checks the key with Apple straight away and shows a result for **Sandbox** and for
**Production**. With a Sandbox & Production key, both say **Valid**.

The check can't see a Topic Specific key's list of apps. If the key doesn't include your app, the
first test push tells you.

<!-- screenshot: the upload form, Team ID covered -->

## When something goes wrong

| Pushwren says | What it means | What to do |
| --- | --- | --- |
| **Not enabled for sandbox** (or production) | The key works in the other environment only. | Edit the key on developer.apple.com to cover both, or upload a second key. |
| **Check the Key ID and Team ID** | Apple didn't accept this key with these IDs. | Copy the Key ID from the file name and the Team ID from Membership details, and make sure the `.p8` is the file for that key. |
| **Key doesn't cover this app** | The key is Topic Specific, and your bundle ID isn't one of its apps. | Edit the key to include the app, or make a Team Scoped key. |
| **Not yet verified** | Apple's answer didn't settle it. | Send a test push from the portal to confirm. |
| Every push fails after working before | The key was revoked on developer.apple.com. | Make a new key and upload it in **Settings → APNs**. |
