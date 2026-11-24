import Foundation
#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// One Live Activity, as the tracker sees it: plain values and callbacks, so the tracking logic
/// compiles everywhere and tests drive it without a device. On iOS, `ActivityKitActivity` wraps
/// ActivityKit's `Activity`. The sequences are read in the caller's task, never in one of their
/// own, so no generic code captures an activity type in a task.
protocol LiveActivityHandle: Sendable {
    /// ActivityKit's ID for the activity, unique on this device.
    var id: String { get }
    /// What Apple matches as `attributes-type`: the Swift type's name.
    var attributesType: String { get }
    /// The key a remote start wrote into the attributes, for `PushwrenActivityAttributes` types.
    var pushwrenKey: String? { get }
    /// True once the activity has ended or been dismissed.
    var isOver: Bool { get }
    /// Calls `body` with the update token as Apple issues it: the current one first, if any, then
    /// each rotation. Returns when the sequence ends or the task is cancelled.
    func pushTokens(_ body: @Sendable (Data) async -> Void) async
    /// Returns once the activity has ended or been dismissed.
    func waitUntilOver() async
}

/// One activity type with remote start (iOS 17.2 and later).
protocol LiveActivityKind: Sendable {
    var attributesType: String { get }
    /// Calls `body` with the type's push-to-start token: the current one first, if any, then each
    /// rotation. Returns when the sequence ends or the task is cancelled.
    func pushToStartTokens(_ body: @Sendable (Data) async -> Void) async
    /// Calls `body` with the type's activities running now, then each one started later, by the
    /// app or by a push.
    func activities(_ body: @Sendable (any LiveActivityHandle) async -> Void) async
}

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)

/// ActivityKit's `Activity`, behind `LiveActivityHandle`. `Activity` is a class Apple's samples
/// read from any task, but the SDK doesn't mark it Sendable; this only reads it.
@available(iOS 16.1, *)
struct ActivityKitActivity<A: ActivityAttributes>: LiveActivityHandle, @unchecked Sendable {
    let activity: Activity<A>
    let pushwrenKey: String?

    var id: String { activity.id }
    var attributesType: String { LiveActivityTracker.attributesType(of: A.self) }
    var isOver: Bool { Self.isOver(activity.activityState) }

    func pushTokens(_ body: @Sendable (Data) async -> Void) async {
        if let token = activity.pushToken { await body(token) }
        for await token in activity.pushTokenUpdates { await body(token) }
    }

    func waitUntilOver() async {
        if isOver { return }
        for await state in activity.activityStateUpdates where Self.isOver(state) { return }
    }

    static func isOver(_ state: ActivityState) -> Bool { state == .ended || state == .dismissed }
}

/// `Activity<A>`'s type-wide sequences, behind `LiveActivityKind`.
@available(iOS 17.2, *)
struct ActivityKitKind<A: PushwrenActivityAttributes>: LiveActivityKind {
    var attributesType: String { LiveActivityTracker.attributesType(of: A.self) }

    func pushToStartTokens(_ body: @Sendable (Data) async -> Void) async {
        if let token = Activity<A>.pushToStartToken { await body(token) }
        for await token in Activity<A>.pushToStartTokenUpdates { await body(token) }
    }

    func activities(_ body: @Sendable (any LiveActivityHandle) async -> Void) async {
        // The tracker ignores an activity it already tracks, so one seen twice is harmless.
        for activity in Activity<A>.activities { await body(Self.handle(activity)) }
        for await activity in Activity<A>.activityUpdates { await body(Self.handle(activity)) }
    }

    private static func handle(_ activity: Activity<A>) -> any LiveActivityHandle {
        ActivityKitActivity(activity: activity, pushwrenKey: activity.attributes.pushwrenKey)
    }
}

#endif
