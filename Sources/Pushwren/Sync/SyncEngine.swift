import Foundation

/// The outcome of the latest sync attempt, for diagnostics.
struct SyncResult: Sendable, Equatable {
    let at: Date
    /// nil when the server accepted the registration.
    let error: APIError?
}

/// Keeps the device record in step with the app (spec section 8, "Sync" and "Reliability").
/// Every change is saved first, then sent as one full registration: only when something changed
/// or the last successful sync is more than 7 days old. Changes within the debounce window go out
/// together. Failures back off and retry; the change stays saved until the server takes it, even
/// across relaunches.
actor SyncEngine {
    static let refreshInterval: TimeInterval = 7 * 86_400

    private let client: APIClient
    private let identity: IdentityStore
    private let store: StateStore
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let debounce: TimeInterval

    private var state: PersistedState
    private var running: Task<Void, Never>?
    private(set) var lastResult: SyncResult?

    init(
        client: APIClient,
        identity: IdentityStore,
        store: StateStore,
        initial: DeviceState,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) },
        debounce: TimeInterval = 1
    ) {
        self.client = client
        self.identity = identity
        self.store = store
        self.now = now
        self.sleep = sleep
        self.debounce = debounce
        self.state = store.load() ?? PersistedState(desired: initial)
    }

    var desired: DeviceState { state.desired }
    var deviceID: String? { identity.load()?.deviceID }

    /// Applies a change, saves it, and schedules a sync. A change that changes nothing does nothing.
    func update(_ change: @Sendable (inout DeviceState) -> Void) {
        var next = state.desired
        change(&next)
        guard next != state.desired else { return }
        state.desired = next
        store.save(state)
        schedule(after: debounce)
    }

    /// Syncs now if anything is due (a change not yet accepted, or a refresh), and waits for it.
    func syncIfNeeded() async {
        schedule(after: 0)
        await settle()
    }

    /// Waits until no sync is running.
    func settle() async {
        while let task = running { await task.value }
    }

    /// Abandons any scheduled sync. The saved state is kept for next time.
    func stop() {
        running?.cancel()
        running = nil
    }

    private func schedule(after delay: TimeInterval) {
        guard running == nil else { return }
        running = Task { [sleep] in
            await sleep(delay)
            await self.run()
        }
    }

    private func run() async {
        defer { running = nil }
        var attempt = 0
        var startedOver = false
        while !Task.isCancelled {
            guard let payload = state.desired.payload() else { return }
            let stale = state.lastSyncAt.map { now().timeIntervalSince($0) > Self.refreshInterval } ?? true
            guard payload != state.lastSent || stale else { return }

            let current = identity.load() ?? {
                let fresh = (deviceID: ULID.deviceID(now: now()), secret: String?.none)
                identity.save(deviceID: fresh.deviceID, secret: nil)
                return fresh
            }()
            do {
                let secret = try await client.putDevice(current.deviceID, payload, secret: current.secret)
                if let secret { identity.save(deviceID: current.deviceID, secret: secret) }
                state.lastSent = payload
                state.lastSyncAt = now()
                store.save(state)
                lastResult = SyncResult(at: now(), error: nil)
                attempt = 0
                Log.info("Registered device \(current.deviceID), token \(Log.tail(payload.token))")
                // Loop: a change made while this request was in flight goes out next.
            } catch .forbidden where !startedOver {
                // The server knows this device ID under a secret we no longer have. Start over,
                // once, as a new device; token uniqueness removes the old record on the server.
                Log.info("Device \(current.deviceID) was refused; registering as a new device")
                identity.reset()
                startedOver = true
            } catch {
                lastResult = SyncResult(at: now(), error: error)
                guard let wait = RetryPolicy.delay(attempt: attempt, error: error) else {
                    Log.error("Pushwren registration failed: \(error)")
                    return
                }
                attempt += 1
                await sleep(wait)
            }
        }
    }
}
