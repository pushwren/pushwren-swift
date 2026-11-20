import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Pushwren: push notifications for Apple apps. Call `configure(appKey:)` once at launch, and
/// make `PushwrenAppDelegate` the app delegate (or forward its three calls). Everything else
/// is optional.
public enum Pushwren {
    // MARK: Setup

    /// Starts Pushwren with a publishable key ("pk_live_…", or "pk_dev_…" for Pushwren's dev API).
    /// Returns at once: detection, registration and the network all happen in the background.
    /// `environment` overrides the APNs environment read from the build's entitlement.
    @MainActor
    public static func configure(appKey: String, environment: ApsEnvironment? = nil) {
        guard let key = AppKey(appKey) else {
            Log.error("Pushwren.configure needs a publishable key (pk_live_… or pk_dev_…). Never put a secret key (sk_…) in an app.")
            return
        }
        hooks.start(key, environment)
        hooks.registerForRemoteNotifications()
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
        let status = AuthorizationStatus(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
        enqueue { await Runtime.shared.apply { $0.authorizationStatus = status } }
        return status
    }

    // MARK: User and tags

    /// Links this device to a user of your app. `signature` is needed only when the app has
    /// identity verification on: HMAC-SHA256 of the user ID, as hex, made by your server.
    public static func setUserID(_ userID: String, signature: String? = nil) {
        enqueue { await Runtime.shared.apply { $0.userId = userID; $0.userIdSignature = signature } }
    }

    /// Unlinks the device from its user, for example on sign-out.
    public static func clearUserID() {
        enqueue { await Runtime.shared.apply { $0.userId = nil; $0.userIdSignature = nil } }
    }

    public static func addTags(_ tags: [String]) {
        let clean = cleanTags(tags)
        enqueue { await Runtime.shared.apply { $0.tags = Array(Set($0.tags).union(clean)).sorted() } }
    }

    public static func removeTags(_ tags: [String]) {
        let clean = Set(cleanTags(tags))
        enqueue { await Runtime.shared.apply { $0.tags = $0.tags.filter { !clean.contains($0) } } }
    }

    // MARK: Debugging

    /// This device's Pushwren ID, to find it in the portal. nil before the first `configure`.
    public static var deviceID: String? { KeychainIdentityStore().load()?.deviceID }

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

    public static func didReceive(response: UNNotificationResponse) {
        // Open tracking arrives in a later release; for now the tap is only logged.
        Log.info("Notification opened: \(response.notification.request.identifier)")
    }

    // MARK: Internals

    /// Seams for tests: what `configure` starts, and how it asks the system for a token.
    struct Hooks {
        var start: @Sendable (AppKey, ApsEnvironment?) -> Void
        var registerForRemoteNotifications: @MainActor () -> Void

        static let live = Hooks(
            start: { key, environment in enqueue { await Runtime.shared.start(key: key, override: environment) } },
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

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func cleanTags(_ tags: [String]) -> [String] {
        tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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

    init(
        deviceID: String?,
        token: String?,
        environment: ApsEnvironment?,
        environmentWarning: String?,
        permission: AuthorizationStatus?,
        apiHost: String?,
        lastSync: Date?,
        lastError: String?
    ) {
        self.deviceID = deviceID
        self.token = token.map { Log.tail($0) }
        self.environment = environment
        self.environmentWarning = environmentWarning
        self.permission = permission
        self.apiHost = apiHost
        self.lastSync = lastSync
        self.lastError = lastError
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
        ].joined(separator: "\n")
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
    private var pending: [@Sendable (inout DeviceState) -> Void] = []

    func start(key: AppKey, override: ApsEnvironment?) async {
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
        if identity.load() == nil { identity.save(deviceID: ULID.deviceID(), secret: nil) }

        let platform = Platform.current
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let engine = SyncEngine(
            client: APIClient(key: key),
            identity: identity,
            store: FileStateStore.standard(),
            initial: DeviceState(platform: platform, bundleId: bundleID, sdkVersion: SDK.version)
        )
        self.engine = engine

        let facts = DeviceFacts.current()
        let environment = override ?? detection.environment
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
        }
        for change in pending { await engine.update(change) }
        pending = []
        observeForeground()
        await refreshPermission()
        // Sends anything saved but not yet accepted, or the weekly refresh, without holding up
        // the calls queued behind this one.
        Task { await engine.syncIfNeeded() }
    }

    func apply(_ change: @escaping @Sendable (inout DeviceState) -> Void) async {
        if let engine { await engine.update(change) } else { pending.append(change) }
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
        let status = AuthorizationStatus(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
        await apply { $0.authorizationStatus = status }
    }

    func diagnostics() async -> Diagnostics {
        let desired = await engine?.desired
        let result = await engine?.lastResult
        return Diagnostics(
            deviceID: await engine?.deviceID ?? KeychainIdentityStore().load()?.deviceID,
            token: desired?.token,
            environment: desired?.environment,
            environmentWarning: detection?.warning,
            permission: desired?.authorizationStatus,
            apiHost: key?.apiBaseURL.host,
            lastSync: result?.error == nil ? result?.at : nil,
            lastError: registrationError ?? result?.error.map { "\($0)" }
        )
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
        }
    }
}

/// The device facts a registration carries besides the token.
struct DeviceFacts: Sendable {
    let appVersion: String?
    let osVersion: String
    let locale: String
    let timezone: String
    let model: String

    static func current() -> DeviceFacts {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceFacts(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            osVersion: v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            locale: Locale.current.identifier(.bcp47),
            timezone: TimeZone.current.identifier,
            model: Platform.modelIdentifier
        )
    }
}
