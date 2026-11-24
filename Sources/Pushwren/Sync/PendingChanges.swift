import Foundation

/// Tag and user-ID changes the app made that the server hasn't taken yet. They go out as
/// PATCH operations, never as a full set, so tags and user IDs your server sets survive the
/// device's next sync (the merge rule: changes from both sides are kept; for the user ID the
/// last writer wins). Live Activity reports wait here too, in order (0.4.0).
struct PendingChanges: Codable, Equatable, Sendable {
    enum UserChange: Codable, Equatable, Sendable {
        case set(id: String, signature: String?)
        case clear
    }

    var add: Set<String> = []
    var remove: Set<String> = []
    var user: UserChange?
    /// Live Activity tokens and ends, oldest first, each sent as its own request.
    var activities: [ActivityReport] = []

    /// One PATCH holds at most this many tag changes, as the server allows.
    static let maxTagChanges = 98
    /// Live Activity reports kept while the device can't send them; older ones are dropped beyond this.
    static let maxActivityReports = 100

    init() {}

    private enum CodingKeys: String, CodingKey { case add, remove, user, activities }

    /// Reads what 0.3.x saved too, which had no Live Activity reports.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        add = try c.decodeIfPresent(Set<String>.self, forKey: .add) ?? []
        remove = try c.decodeIfPresent(Set<String>.self, forKey: .remove) ?? []
        user = try c.decodeIfPresent(UserChange.self, forKey: .user)
        activities = try c.decodeIfPresent([ActivityReport].self, forKey: .activities) ?? []
    }

    /// Queues a Live Activity report. A newer token replaces an unsent one for the same key (or,
    /// for a start token, the same type). An end replaces its key's unsent token, which is moot
    /// once the activity is over, so an end always goes after every token for its key; a token
    /// reported after the end (a new activity under the key) goes after it.
    mutating func report(_ report: ActivityReport) {
        switch report {
        case let .token(key, _, _), let .ended(key):
            activities.removeAll { $0.activityKey == key && ($0.isToken || $0 == report) }
        case let .startToken(type, _):
            activities.removeAll { if case .startToken(type, _) = $0 { true } else { false } }
        }
        activities.append(report)
        if activities.count > Self.maxActivityReports {
            Log.error("Pushwren dropped \(activities.count - Self.maxActivityReports) Live Activity reports it couldn't send")
            activities.removeFirst(activities.count - Self.maxActivityReports)
        }
    }

    /// Forgets the report once the server has answered it, keeping any made while it was in flight.
    mutating func clear(sent: ActivityReport) {
        if let i = activities.firstIndex(of: sent) { activities.remove(at: i) }
    }

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

/// A Live Activity fact the server hasn't taken yet. Tokens are lowercase hex.
enum ActivityReport: Codable, Equatable, Sendable, CustomStringConvertible {
    /// An activity's update token, under its key: PUT /v1/devices/{id}/live-activities/{key}.
    case token(key: String, token: String, attributesType: String)
    /// The activity ended on this device: DELETE /v1/devices/{id}/live-activities/{key}.
    case ended(key: String)
    /// The push-to-start token for an activity type: PUT /v1/devices/{id}/start-tokens/{type}.
    case startToken(attributesType: String, token: String)

    /// The key a token or end is for; nil for a start token.
    var activityKey: String? {
        switch self {
        case let .token(key, _, _), let .ended(key): key
        case .startToken: nil
        }
    }

    var isToken: Bool {
        if case .token = self { true } else { false }
    }

    /// For the log: never a whole token.
    var description: String {
        switch self {
        case let .token(key, token, type): "the \(type) update token \(Log.tail(token)) for \(key)"
        case let .ended(key): "the end of \(key)"
        case let .startToken(type, token): "the \(type) push-to-start token \(Log.tail(token))"
        }
    }
}
