import Foundation

/// The outcome of the latest sync attempt, for diagnostics.
struct SyncResult: Sendable, Equatable {
    let at: Date
    /// nil when the server accepted the registration.
    let error: APIError?
}

/// Keeps the device record in step with the app (spec section 8, "Sync" and "Reliability").
/// Every change is saved first. Device fields go out as one registration (PUT), only when
/// something changed, the API host changed, or the last successful sync is more than 7 days old.
/// Tags and the user ID go out as PATCH operations after it, so the developer's server can change
/// them too (the merge rule). Live Activity tokens and ends go out after them, one request each.
/// Changes within the debounce window go out together. Failures back off and retry; a change
/// stays saved until the server takes it, even across relaunches.
///
/// 0.6.0: in manual mode a phone not registered yet sends nothing until `register()`. A device the
/// server deleted (410 `device_deleted`), or one `deleteRecord` deleted, stops: it forgets its
/// identity, user and tags and sends nothing, across relaunches, until `register()`.
actor SyncEngine {
    static let refreshInterval: TimeInterval = 7 * 86_400

    private let client: APIClient
    private let identity: IdentityStore
    private let store: StateStore
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let debounce: TimeInterval
    /// Called when the server made a new record for this device, which has none of the Live
    /// Activity tokens reported before: the tracker reports the ones it knows again.
    private let onNewRecord: @Sendable () -> Void

    private var state: PersistedState
    private var running: Task<Void, Never>?
    /// Which scheduled run `running` is, so an abandoned run finishing late can't clear a newer one.
    private var generation = 0
    /// True while `deleteRecord` talks to the server: nothing else may sync then.
    private var deleting = false
    /// The wait before the next retry, when one is in progress: a user change or a foreground cuts it short.
    private var backoff: Task<Void, Never>?
    private(set) var lastResult: SyncResult?
    /// The last change the server refused for good, which was dropped (0.3.0: shown in diagnostics).
    private(set) var lastRejected: SyncResult?
    /// The user change the server took during this launch. Setting the same user again sends nothing,
    /// until the next launch (the developer's server may have changed it meanwhile).
    private var userConfirmed: PendingChanges.UserChange?
    /// Manual registration (0.6.0): true until `register()`, for a phone without a record yet.
    private var holdUnregistered: Bool

    init(
        client: APIClient,
        identity: IdentityStore,
        store: StateStore,
        initial: DeviceState,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = SyncEngine.sleep,
        debounce: TimeInterval = 1,
        freshIdentity: Bool = false,
        manual: Bool = false,
        onNewRecord: @escaping @Sendable () -> Void = {}
    ) {
        self.holdUnregistered = manual
        self.client = client
        self.identity = identity
        self.store = store
        self.now = now
        self.sleep = sleep
        self.debounce = debounce
        self.onNewRecord = onNewRecord
        let saved = store.load()
        var state = saved ?? PersistedState(desired: initial)
        if saved == nil, !store.exists, !freshIdentity, (try? identity.load()) != nil {
            // An identity in the Keychain but no state file: the app was deleted and installed again.
            // The server still has the old install's user and tags; replace them with none. A user
            // the app sets during this launch replaces the clear.
            state.clearServerTags = true
            state.pending.user = .clear
        }
        if freshIdentity {
            // No identity in the Keychain but a state file: a backup restored onto another device.
            // Its token belongs to the old device; keep the user's settings, wait for our own token.
            state.desired.token = nil
            state.lastSent = nil
            state.lastSyncAt = nil
        }
        self.state = state
        // A register() from an earlier launch still counts (final review 4).
        if state.registrationRequested == true { holdUnregistered = false }
    }

    /// Waits, clamped to 0...3600 s so a bad value can never trap the conversion.
    static let sleep: @Sendable (TimeInterval) async -> Void = { seconds in
        let s = seconds.isFinite ? min(max(seconds, 0), 3600) : 60
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    var desired: DeviceState { state.desired }
    /// The last registration the server accepted, from any launch.
    var lastSyncAt: Date? { state.lastSyncAt }
    var deviceID: String? { (try? identity.load())??.deviceID }
    /// Why nothing is sent until `register()`, if so.
    var stopped: Stopped? { state.stopped }
    /// The phone has a record on the server (the server gave it a secret).
    private var isRegistered: Bool { (try? identity.load())??.secret != nil }
    /// Whether the app may ask iOS for a device token: not while stopped, nor before `register()` in manual mode.
    var mayRequestToken: Bool { state.stopped == nil && !(holdUnregistered && !isRegistered) }

    /// `Pushwren.register()`: starts a manual-mode phone's registration, or restarts a stopped one
    /// with a new device ID and nothing carried over. False when the phone is registered already.
    func register() -> Bool {
        if state.stopped != nil {
            state.stopped = nil
            state.registrationRequested = true
            holdUnregistered = false
            // A new ID: never the deleted one.
            identity.reset()
            state.lastSent = nil
            state.lastSyncAt = nil
            store.save(state)
            Log.info("Pushwren.register(): registering again with a new device ID")
            schedule(after: 0)
            return true
        }
        guard holdUnregistered, !isRegistered else { return false }
        holdUnregistered = false
        state.registrationRequested = true
        store.save(state)
        Log.info("Pushwren.register(): registering this device")
        schedule(after: 0)
        return true
    }

    /// While stopped, the app's changes are dropped (and say so), not saved for later.
    private func droppedWhileStopped(_ what: String) -> Bool {
        guard state.stopped != nil else { return false }
        Log.info("Pushwren dropped \(what): this device was deleted. Call Pushwren.register() to register again.")
        return true
    }

    /// Applies a change, saves it, and schedules a sync. A change that changes nothing does nothing.
    func update(_ change: @Sendable (inout DeviceState) -> Void) {
        var next = state.desired
        change(&next)
        guard next != state.desired else { return }
        state.desired = next
        store.save(state)
        schedule(after: debounce)
    }

    /// Adds tags (at most 50 on the device; the rest are dropped and logged) and queues the change.
    func addTags(_ tags: [String]) {
        if droppedWhileStopped("a tag change") { return }
        let known = Pushwren.merge(tags: state.desired.tags, adding: tags)
        state.desired.tags = known
        state.pending.addTags(tags.filter { known.contains($0) })
        changed()
    }

    func removeTags(_ tags: [String]) {
        if droppedWhileStopped("a tag change") { return }
        state.desired.tags = state.desired.tags.filter { !tags.contains($0) }
        state.pending.removeTags(tags)
        changed()
    }

    func setUser(_ id: String, signature: String?) {
        if droppedWhileStopped("setUserID") { return }
        let change = PendingChanges.UserChange.set(id: id, signature: signature)
        if state.pending.user == nil, userConfirmed == change, state.desired.userId == id, state.desired.userIdSignature == signature { return }
        state.desired.userId = id
        state.desired.userIdSignature = signature
        state.pending.user = change
        changed(urgent: true)
    }

    func clearUser() {
        if droppedWhileStopped("clearUserID") { return }
        if state.pending.user == nil, userConfirmed == .clear, state.desired.userId == nil { return }
        state.desired.userId = nil
        state.desired.userIdSignature = nil
        state.pending.user = .clear
        changed(urgent: true)
    }

    /// Opens kept while the device can't report them; older ones are dropped beyond this.
    static let maxQueuedOpens = 100

    /// Queues an `opened` event; it goes out once the device has its secret. `receiptRequested`:
    /// the push asked for a delivery receipt, which the event says.
    func recordOpen(_ notificationID: String, receiptRequested: Bool = false) {
        if droppedWhileStopped("an open") { return }
        // The person switched analytics off: the tap reaches the app (`Pushwren.opens`), not Pushwren.
        guard state.desired.analytics != false else { return }
        guard !state.opens.contains(notificationID) else { return }
        state.opens.append(notificationID)
        if receiptRequested { state.opensWithReceipt.append(notificationID) }
        if state.opens.count > Self.maxQueuedOpens {
            state.opens.removeFirst(state.opens.count - Self.maxQueuedOpens)
            let queued = state.opens
            state.opensWithReceipt.removeAll { !queued.contains($0) }
        }
        changed()
    }

    /// Whether this app version and build ships Pushwren's extension helper. A yes is saved and
    /// reused until the version or build changes; a no is checked again at each launch, so an
    /// extension added during development counts without a new build number.
    func serviceExtension(appVersion: String?, build: String?, detect: @Sendable () -> Bool) -> Bool {
        if let saved = state.serviceExtensionCheck, saved.found, saved.appVersion == appVersion, saved.build == build {
            return true
        }
        let check = ServiceExtensionCheck(appVersion: appVersion, build: build, found: detect())
        if check != state.serviceExtensionCheck {
            state.serviceExtensionCheck = check
            store.save(state)
        }
        return check.found
    }

    /// Queues a Live Activity token or end; it goes out once the device is registered.
    func reportActivity(_ report: ActivityReport) {
        if droppedWhileStopped("\(report)") { return }
        state.pending.report(report)
        changed()
    }

    /// The broadcast channel ID of `key` in this device's APNs environment. Never creates one.
    func channel(for key: String) async throws(LiveActivityError) -> String {
        let stored: (deviceID: String, secret: String?)?
        do { stored = try identity.load() } catch { throw .notRegistered }
        guard let stored, let secret = stored.secret else { throw .notRegistered }
        do {
            return try await client.liveActivityChannel(key: key, deviceID: stored.deviceID, secret: secret)
        } catch .rejected(let code, _) where code == "not_found" {
            throw .noChannel
        } catch {
            throw .requestFailed("\(error)")
        }
    }

    /// Saves and schedules a sync. An urgent change (the user) also cuts short a retry's wait:
    /// sign-out shouldn't sit behind a long backoff.
    private func changed(urgent: Bool = false) {
        store.save(state)
        schedule(after: debounce)
        if urgent { backoff?.cancel() }
    }

    /// The tags and user the app has set, all queued again: the server made a new record. Queued
    /// Live Activity reports stay, and the tracker reports the tokens it knows again.
    private func reapplyKnown() {
        var all = PendingChanges()
        all.addTags(state.desired.tags)
        if let id = state.desired.userId { all.user = .set(id: id, signature: state.desired.userIdSignature) }
        all.activities = state.pending.activities
        state.pending = all
        onNewRecord()
    }

    /// Syncs now if anything is due (a change not yet accepted, or a refresh), and waits for it.
    func syncIfNeeded() async {
        schedule(after: 0)
        backoff?.cancel()
        await settle()
    }

    /// Waits until no sync is running.
    func settle() async {
        while let task = running { await task.value }
    }

    /// Deletes this device's record on the server, for when a user deletes their account, then
    /// forgets the device ID, user and tags and stops (0.6.0): it registers again, as a new device
    /// with no user, only once the app calls `register()`. False when the server couldn't be
    /// reached: nothing is forgotten, so the app can try again.
    func deleteRecord() async -> Bool {
        deleting = true
        defer {
            deleting = false
        }
        let inFlight = running
        inFlight?.cancel()
        backoff?.cancel()
        await inFlight?.value
        let stored: (deviceID: String, secret: String?)?
        do { stored = try identity.load() } catch { return false }
        if let stored, let secret = stored.secret {
            do {
                try await client.deleteDevice(stored.deviceID, secret: secret)
            } catch .forbidden {
                // No record under our secret: there's nothing of ours left to delete.
            } catch {
                lastResult = SyncResult(at: now(), error: error)
                Log.error("Pushwren couldn't delete the device: \(error)")
                return false
            }
        }
        forgetAndStop()
        Log.info("Deleted the device from Pushwren; it registers again once the app calls Pushwren.register()")
        return true
    }

    /// Forgets the device ID, user, tags and everything queued, and stops until `register()`.
    private func forgetAndStop() {
        identity.reset()
        state.desired.userId = nil
        state.desired.userIdSignature = nil
        state.desired.tags = []
        state.pending = PendingChanges()
        state.opens = []
        state.opensWithReceipt = []
        state.lastSent = nil
        state.lastSyncAt = nil
        state.clearServerTags = false
        state.stopped = .deleted
        state.registrationRequested = nil
        userConfirmed = nil
        lastRejected = nil
        store.save(state)
    }

    /// Abandons any scheduled sync. The saved state is kept for next time.
    func stop() {
        running?.cancel()
        backoff?.cancel()
        running = nil
    }

    private func schedule(after delay: TimeInterval) {
        guard running == nil, !deleting else { return }
        generation += 1
        let mine = generation
        running = Task { [sleep] in
            await sleep(delay)
            await self.run(generation: mine)
        }
    }

    private func run(generation mine: Int) async {
        defer { if generation == mine { running = nil } }
        var attempt = 0
        var startedOver = false
        while !Task.isCancelled {
            // Stopped: nothing goes out until register() (0.6.0).
            guard state.stopped == nil else { return }
            guard let payload = state.desired.payload() else { return }
            let host = client.key.apiBaseURL.host
            let stale = state.lastSyncAt.map { now().timeIntervalSince($0) > Self.refreshInterval } ?? true
            let needsPut = payload != state.lastSent || stale || state.lastSentHost != host
            let patch = state.pending.patch()
            let report = state.pending.activities.first
            let open = state.opens.first
            guard needsPut || patch != nil || report != nil || open != nil else { return }

            let stored: (deviceID: String, secret: String?)?
            do {
                stored = try identity.load()
            } catch {
                // Never mint a new identity over one we merely can't read yet. The change stays
                // saved and goes out at the next launch, change or foreground.
                lastResult = SyncResult(at: now(), error: .transient)
                return
            }
            // Manual mode: a phone with no record waits for register(); a registered one syncs as usual.
            if holdUnregistered, stored?.secret == nil { return }
            let current = stored ?? {
                let fresh = (deviceID: ULID.deviceID(now: now()), secret: String?.none)
                identity.save(deviceID: fresh.deviceID, secret: nil)
                return fresh
            }()
            do {
                if needsPut || current.secret == nil {
                    let secret = try await client.putDevice(current.deviceID, payload, secret: current.secret, clearTags: state.clearServerTags)
                    state.clearServerTags = false
                    if let secret {
                        identity.save(deviceID: current.deviceID, secret: secret)
                        // A new record on the server: it has none of the app's tags or user yet.
                        reapplyKnown()
                    }
                    state.lastSent = payload
                    state.lastSyncAt = now()
                    state.lastSentHost = host
                    Log.info("Registered device \(current.deviceID), token \(Log.tail(payload.token))")
                } else if let patch, let secret = current.secret {
                    do {
                        try await client.patchDevice(current.deviceID, patch, secret: secret)
                        // Only what was sent: a change made while the request was in flight goes out next.
                        state.pending.clear(sent: patch)
                        if let user = patch.user { userConfirmed = user }
                    } catch .rejected(let code, let message) where code != "not_found" {
                        // The server will never take this change (say, more than 50 tags once its own
                        // are counted). Drop it rather than block every later change and open behind it,
                        // and say so in diagnostics. A user change sent with rejected tags goes again
                        // alone; a rejected signature drops only the user change, and the tags go again.
                        lastRejected = SyncResult(at: now(), error: .rejected(code: code, message: message))
                        let hasTags = !patch.addTags.isEmpty || !patch.removeTags.isEmpty
                        if code == "invalid_user_signature" {
                            Log.error("Pushwren dropped a user ID without a valid signature: identity verification is on. \(message)")
                            if state.pending.user == patch.user { state.pending.user = nil }
                        } else if hasTags, patch.user != nil {
                            Log.error("Pushwren dropped a tag change the server rejected: \(code): \(message)")
                            state.pending.clearTags(sent: patch)
                        } else {
                            Log.error("Pushwren dropped a \(hasTags ? "tag" : "user") change the server rejected: \(code): \(message)")
                            state.pending.clear(sent: patch)
                        }
                    }
                } else if let report, let secret = current.secret {
                    do {
                        try await client.send(report, deviceID: current.deviceID, secret: secret)
                        Log.info("Reported \(report)")
                    } catch .rejected(let code, let message) where code != "not_found" {
                        // A refusal for good (409: the key is a broadcast key, another type's
                        // activity, or one the server started for other devices). Sending it again
                        // won't change the answer: drop it, say so once. A race the server wants
                        // retried is a 503 (try_again), which is transient: the report stays and
                        // goes again after the backoff.
                        lastRejected = SyncResult(at: now(), error: .rejected(code: code, message: message))
                        Log.error("Pushwren dropped \(report), which the server rejected: \(code): \(message)")
                    }
                    state.pending.clear(sent: report)
                } else if let open, let secret = current.secret {
                    do {
                        let receiptRequested = state.opensWithReceipt.contains(open)
                        try await client.postEvent(deviceID: current.deviceID, notificationID: open, receiptRequested: receiptRequested, secret: secret)
                    } catch .rejected {
                        // An unknown or expired notification: the open can never be recorded.
                        Log.info("Pushwren dropped the open of \(open): the server doesn't know it")
                    }
                    state.opens.removeAll { $0 == open }
                    state.opensWithReceipt.removeAll { $0 == open }
                }
                store.save(state)
                lastResult = SyncResult(at: now(), error: nil)
                attempt = 0
            } catch .forbidden where !startedOver {
                // The server knows this device ID under a secret we no longer have. Start over,
                // once, as a new device; token uniqueness removes the old record on the server.
                Log.info("Device \(current.deviceID) was refused; registering as a new device")
                identity.reset()
                startedOver = true
            } catch .deleted where state.clearServerTags && !startedOver {
                // A reinstall launch (identity in the Keychain, no state file) holding a deleted ID:
                // a reinstall is the person's own act, so start fresh with a new ID.
                Log.info("Device \(current.deviceID) was deleted on the server; this reinstall registers as a new device")
                identity.reset()
                state.lastSent = nil
                state.clearServerTags = false
                startedOver = true
            } catch .deleted {
                // The server deleted this device: forget it and stay silent until register().
                forgetAndStop()
                lastResult = nil
                Log.info("Device \(current.deviceID) was deleted on the server. Pushwren sends nothing until the app calls Pushwren.register().")
                return
            } catch .rejected(let code, _) where code == "not_found" && !needsPut && !startedOver {
                // The server deleted the device: register it again, which applies everything anew.
                state.lastSent = nil
                startedOver = true
            } catch {
                lastResult = SyncResult(at: now(), error: error)
                // Stopped or deleting: don't start a wait nothing can cut short.
                if Task.isCancelled { return }
                guard let wait = RetryPolicy.delay(attempt: attempt, error: error) else {
                    Log.error("Pushwren sync failed: \(error)")
                    return
                }
                attempt += 1
                let waiting = Task { [sleep] in await sleep(wait) }
                backoff = waiting
                await waiting.value
                backoff = nil
            }
        }
    }
}
