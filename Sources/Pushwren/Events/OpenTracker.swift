import Foundation
import os

/// A tap on a notification (spec section 8, "Open tracking"), as `Pushwren.opens` yields it.
public struct OpenedNotification: Sendable {
    /// The Pushwren notification ID (the payload's `_h`), or nil for a push that didn't come from Pushwren.
    public let notificationID: String?
    /// `UNNotificationDefaultActionIdentifier` for a plain tap, or the custom action's identifier.
    public let actionIdentifier: String
    /// The payload's custom keys (everything but `aps` and Pushwren's own `_h`, `_i` and `_r`) as JSON.
    public let dataJSON: Data
    /// The push asked for a delivery receipt (it carried `_r`).
    let receiptRequested: Bool

    /// The payload's custom keys, for example `["orderId": "A1001"]`.
    public var data: [String: Any] {
        (try? JSONSerialization.jsonObject(with: dataJSON)) as? [String: Any] ?? [:]
    }

    init(userInfo: [AnyHashable: Any], actionIdentifier: String) {
        let h = userInfo["_h"] as? String
        notificationID = h.flatMap { $0.range(of: "^ntf_[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil ? $0 : nil }
        self.actionIdentifier = actionIdentifier
        receiptRequested = userInfo["_r"] is String
        var custom: [String: Any] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, !Self.reservedKeys.contains(key) else { continue }
            custom[key] = value
        }
        dataJSON = JSONSerialization.isValidJSONObject(custom) ? ((try? JSONSerialization.data(withJSONObject: custom)) ?? Data("{}".utf8)) : Data("{}".utf8)
    }

    /// The payload keys that aren't the app's: Apple's, and Pushwren's notification ID, image URL
    /// and receipt code.
    static let reservedKeys: Set<String> = ["aps", "_h", "_i", "_r"]
}

/// Hands every open to every subscriber of `Pushwren.opens`. Opens that arrive while nobody is
/// subscribed (a cold launch from a tap, before the first view appears) are held, at most 10,
/// and delivered to the next subscriber.
final class OpenBroadcaster: Sendable {
    static let shared = OpenBroadcaster()
    static let bufferLimit = 10

    private struct State {
        var subscribers: [UUID: AsyncStream<OpenedNotification>.Continuation] = [:]
        var buffer: [OpenedNotification] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func subscribe() -> AsyncStream<OpenedNotification> {
        let (stream, continuation) = AsyncStream.makeStream(of: OpenedNotification.self)
        let id = UUID()
        let held = state.withLock { s -> [OpenedNotification] in
            s.subscribers[id] = continuation
            defer { s.buffer = [] }
            return s.buffer
        }
        for open in held { continuation.yield(open) }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ open: OpenedNotification) {
        let subscribers = state.withLock { s -> [AsyncStream<OpenedNotification>.Continuation] in
            if s.subscribers.isEmpty {
                s.buffer.append(open)
                if s.buffer.count > Self.bufferLimit { s.buffer.removeFirst(s.buffer.count - Self.bufferLimit) }
            }
            return Array(s.subscribers.values)
        }
        for c in subscribers { c.yield(open) }
    }
}
