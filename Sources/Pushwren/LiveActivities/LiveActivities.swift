import Foundation
#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Why `Pushwren.liveActivities.channel(for:)` found no channel.
public enum LiveActivityError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The key isn't 1 to 64 letters, digits and _ . : -
    case invalidKey
    /// Pushwren isn't configured, or this device hasn't registered yet. Try again once it has.
    case notRegistered
    /// No broadcast key by that name with a channel in this device's APNs environment. Your server
    /// creates one with POST /v1/live-activities/broadcasts.
    case noChannel
    /// Pushwren couldn't be reached, or answered with an error. Try again later.
    case requestFailed(String)

    public var description: String {
        switch self {
        case .invalidKey: "a Live Activity key is 1 to 64 letters, digits and _ . : -"
        case .notRegistered: "this device isn't registered with Pushwren yet"
        case .noChannel: "no broadcast channel for that key in this device's APNs environment"
        case let .requestFailed(reason): "the channel lookup failed: \(reason)"
        }
    }
}

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)

extension Pushwren {
    /// Live Activities (iOS only): hands Pushwren every token Apple issues for them, so your server
    /// updates, ends and starts them by your own key.
    public static let liveActivities = LiveActivities()
}

/// Live Activities, through `Pushwren.liveActivities`. Tokens and ends are queued like every
/// other change: saved first, sent once the device is registered, retried with backoff, and kept
/// across relaunches. Live Activities are iOS and iPadOS only; this API isn't on macOS or Mac Catalyst.
///
/// The activity type Pushwren reports is the Swift type's name, `String(describing: A.self)`:
/// `"OrderAttributes"` for `struct OrderAttributes`. Apple matches it as the push's
/// `attributes-type`, so your server sends exactly that as `attributesType` on a remote start.
public struct LiveActivities: Sendable {
    init() {}

    /// Reports the activity's update token under `key`, again whenever Apple rotates it, and the
    /// activity's end. Your server then updates and ends it by key, on every device that has it.
    ///
    /// Call it right after `Activity.request(…, pushType: .token)`, and at each launch for the
    /// activities still running (`Activity<A>.activities`): Pushwren tracks an activity only while
    /// the app runs. Tracking the same activity twice changes nothing. A key is 1 to 64 letters,
    /// digits and _ . : -, such as "order-A1001"; anything else is logged and not tracked.
    ///
    /// The type is reported as `String(describing: A.self)`, which is what Apple matches as
    /// `attributes-type`. A key already holding another type's activity, or a broadcast key, is
    /// refused (409): Pushwren logs it once and drops the report. For a type with remote start
    /// enabled, Pushwren already tracks every activity under its `pushwrenKey`.
    @available(iOS 16.1, *)
    public func track<A: ActivityAttributes>(_ activity: Activity<A>, key: String) {
        // Type-erased before the job captures it: the job is no longer generic over A.
        let handle: any LiveActivityHandle = ActivityKitActivity(activity: activity, pushwrenKey: nil)
        Pushwren.enqueue { await LiveActivityTracker.shared.track(handle, key: key) }
    }

    /// Lets your server start activities of this type with a push (iOS 17.2 and later). Reports the
    /// type's push-to-start token and each rotation of it, and tracks every activity of the type,
    /// whether a push or the app started it, under its `pushwrenKey`, as `track` does: its update
    /// token (if iOS issues one) and its end. Call it at each launch, after `configure`.
    ///
    /// Your server starts one with `attributesType` set to `String(describing: A.self)`, the Swift
    /// type's name ("OrderAttributes"): that is what Apple matches as `attributes-type`.
    @available(iOS 17.2, *)
    public func enableRemoteStart<A: PushwrenActivityAttributes>(for type: A.Type) {
        let kind: any LiveActivityKind = ActivityKitKind<A>()
        Pushwren.enqueue { await LiveActivityTracker.shared.enableRemoteStart(kind) }
    }

    /// The broadcast channel ID for a key your server created with POST /v1/live-activities/broadcasts,
    /// in this device's APNs environment (iOS 18 and later). Start the activity with
    /// `Activity.request(…, pushType: .channel(channelID))`; it then follows every broadcast update.
    /// Pushwren only looks the channel up and never creates one. Throws `LiveActivityError`.
    @available(iOS 18.0, *)
    public func channel(for key: String) async throws -> String {
        guard LiveActivityTracker.isValidKey(key) else { throw LiveActivityError.invalidKey }
        let result = await withCheckedContinuation { (done: CheckedContinuation<Result<String, LiveActivityError>, Never>) in
            Pushwren.enqueue { done.resume(returning: await Runtime.shared.liveActivityChannel(key)) }
        }
        return try result.get()
    }
}

#endif

/// Follows Live Activities and turns what ActivityKit says into reports for the queue: each new
/// update token under the activity's key, its end, and each type's push-to-start token. One per
/// process; it remembers only what this launch has seen.
actor LiveActivityTracker {
    static let shared = LiveActivityTracker(report: { report in
        Pushwren.enqueue { await Runtime.shared.engineDo { await $0.reportActivity(report) } }
    })

    private struct Tracked {
        let key: String
        let attributesType: String
        /// The last token reported, so the same one twice is reported once.
        var token: String?
        var tasks: [Task<Void, Never>] = []
    }

    /// Hands a report to the queue. Synchronous, so reports keep the order they're made in.
    private let report: @Sendable (ActivityReport) -> Void
    /// By ActivityKit's activity ID.
    private var tracked: [String: Tracked] = [:]
    /// The last push-to-start token reported, by activity type.
    private var startTokens: [String: String] = [:]
    /// The activity types remote start is enabled for: their sequences are followed for the process's life.
    private var remoteStartTypes: Set<String> = []

    init(report: @escaping @Sendable (ActivityReport) -> Void) {
        self.report = report
    }

    /// What Apple matches as `attributes-type` on a remote start: the Swift type's name.
    static func attributesType(of type: Any.Type) -> String { String(describing: type) }

    /// The tag rule the server applies to keys. "." and ".." are refused too: as a path segment
    /// they would address another route.
    static func isValidKey(_ key: String) -> Bool {
        key != "." && key != ".." && key.range(of: "^[A-Za-z0-9_.:-]{1,64}$", options: .regularExpression) != nil
    }

    static func isValidAttributesType(_ type: String) -> Bool {
        (1...128).contains(type.count) && type != "." && type != ".."
    }

    /// The server's token rule: 32 to 100 bytes, as lowercase hex.
    static func isValidToken(_ token: String) -> Bool {
        token.range(of: "^(?:[0-9a-f]{2}){32,100}$", options: .regularExpression) != nil
    }

    func track(_ activity: any LiveActivityHandle, key: String) {
        guard Self.isValidKey(key) else {
            Log.error("Pushwren didn't track the Live Activity \(activity.id) under \"\(key)\": a key is 1 to 64 letters, digits and _ . : -")
            return
        }
        guard Self.isValidAttributesType(activity.attributesType) else {
            Log.error("Pushwren didn't track the Live Activity \(activity.id): its type's name is longer than 128 characters")
            return
        }
        if let known = tracked[activity.id] {
            if known.key != key { Log.info("The Live Activity \(activity.id) is already tracked under \(known.key)") }
            return
        }
        if activity.isOver {
            // Ended while the app wasn't running: the server may still hold its token.
            tracked[activity.id] = Tracked(key: key, attributesType: activity.attributesType)
            ended(activity.id)
            return
        }
        let id = activity.id
        tracked[id] = Tracked(key: key, attributesType: activity.attributesType)
        let tokens = Task {
            await activity.pushTokens { token in await self.received(token, for: id) }
        }
        let end = Task {
            await activity.waitUntilOver()
            if !Task.isCancelled { self.ended(id) }
        }
        tracked[id]?.tasks = [tokens, end]
        Log.info("Tracking the Live Activity \(id) under \(key)")
    }

    func enableRemoteStart(_ kind: any LiveActivityKind) {
        let type = kind.attributesType
        guard !remoteStartTypes.contains(type) else { return }
        guard Self.isValidAttributesType(type) else {
            Log.error("Pushwren can't enable remote start for \(type.prefix(40))…: a type's name is at most 128 characters")
            return
        }
        remoteStartTypes.insert(type)
        Task { await kind.pushToStartTokens { token in await self.received(startToken: token, type: type) } }
        Task { await kind.activities { activity in await self.startedRemotely(activity) } }
        Log.info("Remote start enabled for \(type)")
    }

    /// Reports every token this launch knows again: the server made a new record for the device.
    func reportAgain() {
        for (type, token) in startTokens { report(.startToken(attributesType: type, token: token)) }
        for entry in tracked.values {
            if let token = entry.token { report(.token(key: entry.key, token: token, attributesType: entry.attributesType)) }
        }
    }

    private func startedRemotely(_ activity: any LiveActivityHandle) {
        guard let key = activity.pushwrenKey else { return }
        track(activity, key: key)
    }

    private func received(_ data: Data, for id: String) {
        // An activity that has ended takes no more tokens: its end is already queued.
        guard var entry = tracked[id] else { return }
        let token = Pushwren.hex(data)
        guard token != entry.token else { return }
        guard Self.isValidToken(token) else {
            Log.error("Pushwren ignored a Live Activity token of \(data.count) bytes for \(entry.key)")
            return
        }
        entry.token = token
        tracked[id] = entry
        report(.token(key: entry.key, token: token, attributesType: entry.attributesType))
    }

    private func received(startToken data: Data, type: String) {
        let token = Pushwren.hex(data)
        guard token != startTokens[type] else { return }
        guard Self.isValidToken(token) else {
            Log.error("Pushwren ignored a push-to-start token of \(data.count) bytes for \(type)")
            return
        }
        startTokens[type] = token
        report(.startToken(attributesType: type, token: token))
    }

    private func ended(_ id: String) {
        guard let entry = tracked.removeValue(forKey: id) else { return }
        entry.tasks.forEach { $0.cancel() }
        Log.info("The Live Activity under \(entry.key) ended")
        // Another activity on this device still runs under the key: it keeps the key, with its token.
        if let other = tracked.values.first(where: { $0.key == entry.key && $0.token != nil }), let token = other.token {
            report(.token(key: other.key, token: token, attributesType: other.attributesType))
        } else {
            report(.ended(key: entry.key))
        }
    }
}
