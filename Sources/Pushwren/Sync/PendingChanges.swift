import Foundation

/// Tag and user-ID changes the app made that the server hasn't taken yet. They go out as
/// PATCH operations, never as a full set, so tags and user IDs your server sets survive the
/// device's next sync (the merge rule: changes from both sides are kept; for the user ID the
/// last writer wins).
struct PendingChanges: Codable, Equatable, Sendable {
    enum UserChange: Codable, Equatable, Sendable {
        case set(id: String, signature: String?)
        case clear
    }

    var add: Set<String> = []
    var remove: Set<String> = []
    var user: UserChange?

    /// One PATCH holds at most this many tag changes, as the server allows.
    static let maxTagChanges = 98

    /// The last operation on a tag wins.
    mutating func addTags(_ tags: [String]) {
        for tag in tags {
            add.insert(tag)
            remove.remove(tag)
        }
    }

    mutating func removeTags(_ tags: [String]) {
        for tag in tags {
            remove.insert(tag)
            add.remove(tag)
        }
    }

    /// The next PATCH to send, or nil when nothing is pending. Large tag changes go out over
    /// several PATCHes; the user change rides with the first.
    func patch() -> DevicePatch? {
        guard !add.isEmpty || !remove.isEmpty || user != nil else { return nil }
        let adds = Array(add.sorted().prefix(Self.maxTagChanges))
        let removes = Array(remove.sorted().prefix(Self.maxTagChanges - adds.count))
        return DevicePatch(user: user, addTags: adds, removeTags: removes)
    }

    /// Forgets what `sent` carried, keeping any change made while it was in flight.
    mutating func clear(sent: DevicePatch) {
        clearTags(sent: sent)
        if user == sent.user { user = nil }
    }

    /// Forgets only the tag changes `sent` carried: its user change stays pending.
    mutating func clearTags(sent: DevicePatch) {
        add.subtract(sent.addTags.filter { add.contains($0) })
        remove.subtract(sent.removeTags.filter { remove.contains($0) })
    }
}

/// The body of PATCH /v1/devices/{deviceId}. A cleared user ID is sent as JSON null.
struct DevicePatch: Encodable, Equatable, Sendable {
    let user: PendingChanges.UserChange?
    let addTags: [String]
    let removeTags: [String]

    private enum Keys: String, CodingKey {
        case userId, userIdSignature, addTags, removeTags
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch user {
        case let .set(id, signature):
            try c.encode(id, forKey: .userId)
            if let signature { try c.encode(signature, forKey: .userIdSignature) }
        case .clear:
            try c.encodeNil(forKey: .userId)
        case nil:
            break
        }
        if !addTags.isEmpty { try c.encode(addTags, forKey: .addTags) }
        if !removeTags.isEmpty { try c.encode(removeTags, forKey: .removeTags) }
    }
}
