import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// When a phone registers with Pushwren (0.6.0).
public enum Registration: Sendable {
    /// At launch, as soon as iOS gives a token (the default).
    case automatic
    /// Only once the app calls `Pushwren.register()`, for example at sign-in or after consent. A phone
    /// already registered keeps syncing at each launch.
    case manual
}

/// Pushwren: push notifications for Apple apps. Call `configure(appKey:)` once at launch, and
/// make `PushwrenAppDelegate` the app delegate (or forward its three calls). Everything else
/// is optional.
public enum Pushwren {
    // MARK: Setup

    /// Starts Pushwren with a publishable key ("pk_live_…", or "pk_dev_…" for Pushwren's dev API).
    /// Returns at once: detection, registration and the network all happen in the background.
    /// `environment` overrides the APNs environment read from the build's entitlement. With
    /// `registration: .manual`, a phone that isn't registered yet sends nothing and asks iOS for no
    /// token until the app calls `register()`.
    @MainActor
    public static func configure(appKey: String, environment: ApsEnvironment? = nil, registration: Registration = .automatic) {
        guard let key = AppKey(appKey) else {
            Log.error("Pushwren.configure needs a publishable key (pk_live_… or pk_dev_…). Never put a secret key (sk_…) in an app.")
            return
        }
        hooks.start(key, environment, registration)
    }

    /// Registers this phone with Pushwren: in manual mode, the first time; after the device was
    /// deleted (on the server, or by `deleteDevice()`), again, with a new device ID and nothing
    /// carried over. Does nothing for a phone that is registered already. Call it where the app
    /// decides the person should get notifications, usually sign-in, never at every launch.
    public static func register() {
        enqueue {
            if await Runtime.shared.register() { requestToken() }
        }
    }

    /// How much Pushwren writes to the unified log (subsystem com.pushwren.sdk).
    public static var logLevel: LogLevel {
        get { Log.level }
        set { Log.level = newValue }
    }

    // MARK: Permission

    /// Asks the user to allow notifications, then reports the answer to Pushwren.
    /// With `provisional: true`, notifications are delivered quietly without a prompt.
    public static func requestPermission(provisional: Bool = false) async throws -> AuthorizationStatus {
        var options: UNAuthorizationOptions = [.alert, .badge, .sound]
        if provisional { options.insert(.provisional) }
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        let status = await AuthorizationStatus.current()
        enqueue { await Runtime.shared.apply { $0.authorizationStatus = status } }
        return status
    }

    // MARK: User and tags

    /// Links this device to a user of your app. `signature` is needed only when the app has
    /// identity verification on: HMAC-SHA256 of the user ID, as hex, made by your server.
    public static func setUserID(_ userID: String, signature: String? = nil) {
        guard isValidUserID(userID) else {
            Log.error("Pushwren.setUserID ignored: a user ID is 1 to 128 characters with no control characters")
            return
        }
        let signature = signature.flatMap { s -> String? in
            if let clean = normalizedSignature(s) { return clean }
            Log.error("Pushwren.setUserID: the signature isn't 64 hex characters (HMAC-SHA256); sending the user ID without it")
            return nil
        }
        enqueue { await Runtime.shared.engineDo { await $0.setUser(userID, signature: signature) } }
    }

    /// Unlinks the device from its user, for example on sign-out.
    public static func clearUserID() {
        enqueue { await Runtime.shared.engineDo { await $0.clearUser() } }
    }

    /// Tags are 1 to 64 letters, digits and _ . : -, at most 50 per device. Others are dropped and logged.
    public static func addTags(_ tags: [String]) {
        let clean = cleanTags(tags)
        enqueue { await Runtime.shared.engineDo { await $0.addTags(clean) } }
    }

    public static func removeTags(_ tags: [String]) {
        let clean = cleanTags(tags)
        enqueue { await Runtime.shared.engineDo { await $0.removeTags(clean) } }
    }

    /// Whether taps on this phone's notifications may be counted (default true). With it off, the
    /// phone reports no taps, and Pushwren asks it for no delivery receipts and adds no open marker
    /// to its pushes. Kept across launches; `Pushwren.opens` gets every tap either way.
    public static func setAnalyticsEnabled(_ enabled: Bool) {
        enqueue { await Runtime.shared.apply { $0.analytics = enabled ? nil : false } }
    }

    /// Deletes this device's record from Pushwren, with its user ID and tags: call it when a user
    /// deletes their account. The phone then stays unregistered until the app calls `register()`,
    /// which gives it a new device ID. Returns false when Pushwren couldn't be reached; nothing is
    /// forgotten then.
    @discardableResult
    public static func deleteDevice() async -> Bool {
        // On the same queue as every other call, so a setUserID made before it is applied first.
        await withCheckedContinuation { done in
            enqueue { done.resume(returning: await Runtime.shared.deleteDevice()) }
        }
    }

    // MARK: Debugging

    /// This device's Pushwren ID, to find it in the portal. nil before the first `configure`.
    public static var deviceID: String? { (try? KeychainIdentityStore().load())??.deviceID }

    /// What Pushwren knows about this device: ID, token (last 8 characters), environment,
    /// permission, API host and the last sync.
    public static func diagnostics() async -> Diagnostics { await Runtime.shared.diagnostics() }

    // MARK: Forwarding (apps with their own app delegate)

    public static func didRegister(deviceToken: Data) {
        let token = hex(deviceToken)
        enqueue { await Runtime.shared.didRegister(token: token) }
    }

    public static func didFailToRegister(error: Error) {
        let message = error.localizedDescription
        Log.error("Registering for remote notifications failed: \(message)")
        enqueue { await Runtime.shared.didFailToRegister(message: message) }
    }

    /// Records the tap: it appears on `opens`, and a notification sent by Pushwren with open tracking
    /// on (it carries `_o`) is counted as opened, unless the person switched analytics off.
    public static func didReceive(response: UNNotificationResponse) {
        let open = OpenedNotification(userInfo: response.notification.request.content.userInfo, actionIdentifier: response.actionIdentifier)
        OpenBroadcaster.shared.yield(open)
        guard reports(open), let id = open.notificationID else { return }
        Log.info("Notification opened: \(id)")
        let receiptRequested = open.receiptRequested
        enqueue { await Runtime.shared.engineDo { await $0.recordOpen(id, receiptRequested: receiptRequested) } }
    }

    /// Every notification the user opens, for deep links. Each `for await` gets every open from
    /// then on; opens from before anyone was listening (a launch from a tap) go to the first one.
    public static var opens: AsyncStream<OpenedNotification> { OpenBroadcaster.shared.subscribe() }

    // MARK: Internals

    /// Seams for tests: what `configure` starts, and how it asks the system for a token.
    struct Hooks {
        var start: @Sendable (AppKey, ApsEnvironment?, Registration) -> Void
        var registerForRemoteNotifications: @MainActor () -> Void

        static let live = Hooks(
            start: { key, environment, registration in enqueue { await Runtime.shared.start(key: key, override: environment, registration: registration) } },
            registerForRemoteNotifications: {
                #if canImport(UIKit)
                UIApplication.shared.registerForRemoteNotifications()
                #elseif canImport(AppKit)
                NSApplication.shared.registerForRemoteNotifications()
                #endif
            }
        )
    }

    @MainActor static var hooks = Hooks.live

    /// Asks iOS for a device token. SwiftUI runs App.init before UIApplication exists, so asking at
    /// once could go nowhere: the next turn of the main run loop is after launch, with the delegate set.
    static func requestToken() {
        DispatchQueue.main.async { MainActor.assumeIsolated { hooks.registerForRemoteNotifications() } }
    }

    /// Whether a tap goes to Pushwren at all: a Pushwren notification whose app has open tracking on (0.6.0).
    static func reports(_ open: OpenedNotification) -> Bool { open.notificationID != nil && open.openTracked }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static let maxTags = 50

    /// Trimmed tags that the server will accept; anything else is logged and dropped, so one bad
    /// tag can never block the device's registration.
    static func cleanTags(_ tags: [String]) -> [String] {
        var clean: [String] = []
        for tag in tags.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !tag.isEmpty {
            if tag.range(of: "^[A-Za-z0-9_.:-]{1,64}$", options: .regularExpression) != nil {
                clean.append(tag)
            } else {
                Log.error("Pushwren dropped the tag \"\(tag)\": tags are 1 to 64 letters, digits and _ . : -")
            }
        }
        return clean
    }

    /// The device's tags plus new ones, at most 50. Existing tags win.
    static func merge(tags: [String], adding: [String]) -> [String] {
        var result = tags
        for tag in adding where !result.contains(tag) {
            guard result.count < maxTags else {
                Log.error("Pushwren dropped the tag \"\(tag)\": a device has at most \(maxTags) tags")
                continue
            }
            result.append(tag)
        }
        return result.sorted()
    }

    static func isValidUserID(_ id: String) -> Bool {
        (1...128).contains(id.count) && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// An HMAC-SHA256 signature as the server wants it: 64 lowercase hex characters, or nil.
    static func normalizedSignature(_ signature: String) -> String? {
        let s = signature.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil ? s : nil
    }

    static func refreshPermissionStatus() {
        enqueue { await Runtime.shared.refreshPermission() }
    }

    /// Every public call becomes a job on one queue, run in the order the calls were made.
    private static let jobs = AsyncStream.makeStream(of: (@Sendable () async -> Void).self)
    private static let worker = Task.detached {
        for await job in jobs.stream { await job() }
    }

    static func enqueue(_ job: @escaping @Sendable () async -> Void) {
        _ = worker
        jobs.continuation.yield(job)
    }
}

/// What Pushwren knows about this device. The token appears only as its last 8 characters.
public struct Diagnostics: Sendable, CustomStringConvertible {
    public let deviceID: String?
    /// The device token's last 8 characters, or nil before APNs has issued one.
    public let token: String?
    public let environment: ApsEnvironment?
    public let environmentWarning: String?
    public let permission: AuthorizationStatus?
    public let apiHost: String?
    public let lastSync: Date?
    public let lastError: String?
    /// Set while the SDK sends nothing because the device was deleted (0.6.0).
    public let stopped: String?

    static let deletedMessage = "Deleted on the server. Call Pushwren.register() to register again."

    init(
        deviceID: String?,
        token: String?,
        environment: ApsEnvironment?,
        environmentWarning: String?,
        permission: AuthorizationStatus?,
        apiHost: String?,
        lastSync: Date?,
        lastError: String?,
        stopped: String? = nil
    ) {
        self.deviceID = deviceID
        self.token = token.map { Log.tail($0) }
        self.environment = environment
        self.environmentWarning = environmentWarning
        self.permission = permission
        self.apiHost = apiHost
        self.lastSync = lastSync
        self.lastError = lastError
        self.stopped = stopped
    }

    /// The last sync: this launch's, or the last one saved from any launch.
    static func lastSync(result: SyncResult?, saved: Date?) -> Date? {
        if let result, result.error == nil { return result.at }
        return saved
    }

    /// What went wrong last: registering with APNs, the latest sync, or a change the server refused.
    static func lastError(registration: String?, result: SyncResult?, rejected: SyncResult?) -> String? {
        if let registration { return registration }
        if let error = result?.error { return "\(error)" }
        if case let .rejected(code, message)? = rejected?.error {
            return "dropped a change the server rejected: \(code): \(message)"
        }
        return nil
    }

    public var description: String {
        [
            "Pushwren \(SDK.version)",
            "  device ID:   \(deviceID ?? "none yet")",
            "  token:       \(token ?? "none yet")",
            "  environment: \(environment?.rawValue ?? "unknown")\(environmentWarning.map { " (\($0))" } ?? "")",
            "  permission:  \(permission?.rawValue ?? "unknown")",
            "  API host:    \(apiHost ?? "not configured")",
            "  last sync:   \(lastSync.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
            "  last error:  \(lastError ?? "none")",
        ].joined(separator: "\n") + (stopped.map { "\n  stopped:     \($0)" } ?? "")
    }
}

/// The SDK's running state, one per process. Changes made before `configure` has finished
/// starting are held and applied in order once the sync engine exists.
actor Runtime {
    static let shared = Runtime()

    private var engine: SyncEngine?
    private var key: AppKey?
    private var detection: EnvironmentDetection?
    private var registrationError: String?
    /// Calls made before the engine exists, applied in order once it does.
    private var pending: [@Sendable (SyncEngine) async -> Void] = []

    func start(key: AppKey, override: ApsEnvironment?, registration: Registration = .automatic) async {
        guard engine == nil else {
            Log.info("Pushwren.configure was called again; keeping the first configuration")
            return
        }
        self.key = key
        let detection = EnvironmentDetector.detect()
        self.detection = detection
        if let warning = detection.warning {
            if detection.environment == nil { Log.error(warning) } else { Log.info(warning) }
        }

        let identity = KeychainIdentityStore()
        let freshIdentity: Bool
        do {
            freshIdentity = try identity.load() == nil
        } catch {
            // Before the first unlock after a reboot. Try again once protected data is readable;
            // changes made meanwhile are held in `pending`.
            Log.info("Pushwren will start once the device is unlocked")
            retryStartWhenUnlocked(key: key, override: override, registration: registration)
            return
        }
        if freshIdentity { identity.save(deviceID: ULID.deviceID(), secret: nil) }

        let platform = Platform.current
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let engine = SyncEngine(
            client: APIClient(key: key),
            identity: identity,
            store: FileStateStore.standard(bundleID: bundleID.isEmpty ? "app" : bundleID),
            initial: DeviceState(platform: platform, bundleId: bundleID, sdkVersion: SDK.version),
            freshIdentity: freshIdentity,
            manual: registration == .manual,
            onNewRecord: { Task { await LiveActivityTracker.shared.reportAgain() } }
        )
        self.engine = engine

        let facts = DeviceFacts.current()
        let environment = override ?? detection.environment
        let serviceExtension = await engine.serviceExtension(appVersion: facts.appVersion, build: facts.build) {
            ServiceExtension.detect(in: .main)
        }
        await engine.update { s in
            s.environment = environment
            s.platform = platform
            s.bundleId = bundleID
            s.sdkVersion = SDK.version
            s.appVersion = facts.appVersion
            s.osVersion = facts.osVersion
            s.locale = facts.locale
            s.timezone = facts.timezone
            s.model = facts.model
            s.serviceExtension = serviceExtension
        }
        for call in pending { await call(engine) }
        pending = []
        observeForeground()
        await refreshPermission()
        // No token is asked of iOS while the phone is deleted, or before register() in manual mode.
        if await engine.mayRequestToken { Pushwren.requestToken() }
        // Sends anything saved but not yet accepted, or the weekly refresh, without holding up
        // the calls queued behind this one.
        Task { await engine.syncIfNeeded() }
    }

    func apply(_ change: @escaping @Sendable (inout DeviceState) -> Void) async {
        await engineDo { await $0.update(change) }
    }

    /// Runs a call on the sync engine, or holds it until `configure` has started one.
    func engineDo(_ call: @escaping @Sendable (SyncEngine) async -> Void) async {
        if let engine { await call(engine) } else { pending.append(call) }
    }

    func didRegister(token: String) async {
        registrationError = nil
        await apply { $0.token = token }
    }

    func didFailToRegister(message: String) {
        registrationError = message
    }

    func refreshPermission() async {
        guard engine != nil else { return }
        let status = await AuthorizationStatus.current()
        await apply { $0.authorizationStatus = status }
    }

    func diagnostics() async -> Diagnostics {
        let desired = await engine?.desired
        let result = await engine?.lastResult
        let saved = await engine?.lastSyncAt
        let rejected = await engine?.lastRejected
        return Diagnostics(
            deviceID: await engine?.deviceID ?? (try? KeychainIdentityStore().load())??.deviceID,
            token: desired?.token,
            environment: desired?.environment,
            environmentWarning: detection?.warning,
            permission: desired?.authorizationStatus,
            apiHost: key?.apiBaseURL.host,
            lastSync: Diagnostics.lastSync(result: result, saved: saved),
            lastError: Diagnostics.lastError(registration: registrationError, result: result, rejected: rejected),
            stopped: await engine?.stopped == .deleted ? Diagnostics.deletedMessage : nil
        )
    }

    /// True when it started a registration: the app then asks iOS for a token.
    func register() async -> Bool {
        guard let engine else {
            // Before configure has started the engine: applied once it exists.
            pending.append { engine in if await engine.register() { Pushwren.requestToken() } }
            return false
        }
        return await engine.register()
    }

    func deleteDevice() async -> Bool {
        guard let engine else { return false }
        return await engine.deleteRecord()
    }

    func liveActivityChannel(_ key: String) async -> Result<String, LiveActivityError> {
        guard let engine else { return .failure(.notRegistered) }
        do { return .success(try await engine.channel(for: key)) } catch { return .failure(error) }
    }

    private var waitingForUnlock = false

    private func retryStartWhenUnlocked(key: AppKey, override: ApsEnvironment?, registration: Registration) {
        guard !waitingForUnlock else { return }
        waitingForUnlock = true
        #if canImport(UIKit)
        let name = UIApplication.protectedDataDidBecomeAvailableNotification
        #elseif canImport(AppKit)
        let name = NSApplication.didBecomeActiveNotification
        #endif
        _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            Pushwren.enqueue { await Runtime.shared.retryStart(key: key, override: override, registration: registration) }
        }
    }

    private func retryStart(key: AppKey, override: ApsEnvironment?, registration: Registration) async {
        waitingForUnlock = false
        await start(key: key, override: override, registration: registration)
    }

    /// Permission can change in Settings while the app is away: re-read it on every return.
    private func observeForeground() {
        #if canImport(UIKit)
        let name = UIApplication.willEnterForegroundNotification
        #elseif canImport(AppKit)
        let name = NSApplication.didBecomeActiveNotification
        #endif
        _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            Pushwren.refreshPermissionStatus()
            // The weekly refresh and anything pending, also for apps that stay running for days.
            Pushwren.enqueue { await Runtime.shared.engineDo { engine in Task { await engine.syncIfNeeded() } } }
        }
    }
}

/// The device facts a registration carries besides the token.
struct DeviceFacts: Sendable {
    let appVersion: String?
    /// CFBundleVersion: not sent, but a new build is looked at again for Pushwren's extension.
    let build: String?
    let osVersion: String
    let locale: String
    let timezone: String
    let model: String

    static func current() -> DeviceFacts {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceFacts(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            osVersion: v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            locale: Locale.current.identifier(.bcp47),
            timezone: TimeZone.current.identifier,
            model: Platform.modelIdentifier
        )
    }
}
