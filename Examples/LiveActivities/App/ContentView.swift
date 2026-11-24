import ActivityKit
import Pushwren
import SwiftUI

/// The three ways to run a Live Activity with Pushwren, one button each.
struct ContentView: View {
    @State private var diagnostics = "Starting…"
    @State private var message = ""

    /// The key the app-started order uses; your server updates and ends it by this key.
    private let orderKey = "order-A1001"
    /// A broadcast key your server creates with POST /v1/live-activities/broadcasts.
    private let broadcastKey = "broadcast-demo"

    var body: some View {
        NavigationStack {
            Form {
                Section("This device") {
                    Text(diagnostics)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy device ID") { UIPasteboard.general.string = Pushwren.deviceID ?? "" }
                }
                Section("1. Started by the app (iOS 16.2+)") {
                    Button("Start order A1001") { startOrder() }
                    Button("End every order here", role: .destructive) { Task { await endAll() } }
                }
                Section("2. Started by your server (iOS 17.2+)") {
                    Text("Nothing to tap: the app reports its push-to-start token at launch. Send a start from your server (see the README).")
                        .font(.footnote)
                }
                Section("3. Broadcast (iOS 18+)") {
                    Button("Follow \(broadcastKey)") { Task { await follow() } }
                }
                if !message.isEmpty {
                    Section { Text(message).font(.footnote) }
                }
            }
            .navigationTitle("Orders")
            .toolbar { Button("Refresh") { Task { await refresh() } } }
        }
        .task {
            for _ in 0..<5 {
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func refresh() async { diagnostics = "\(await Pushwren.diagnostics())" }

    private func startOrder() {
        let attributes = OrderAttributes(pushwrenKey: orderKey, orderNumber: "A1001")
        let content = ActivityContent(state: OrderAttributes.ContentState(status: "Received", etaMinutes: 20), staleDate: nil)
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
            // Reports the update token (and each rotation) under the key, and the activity's end.
            Pushwren.liveActivities.track(activity, key: orderKey)
            message = "Started \(orderKey). Update it from your server by that key."
        } catch {
            message = "Couldn't start the activity: \(error.localizedDescription)"
        }
    }

    private func endAll() async {
        for activity in Activity<OrderAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        message = "Ended. Pushwren reports each end, so the server stops sending to this device."
    }

    private func follow() async {
        guard #available(iOS 18.0, *) else {
            message = "Broadcast needs iOS 18."
            return
        }
        do {
            // Only looks the channel up: your server created it for this device's APNs environment.
            let channel = try await Pushwren.liveActivities.channel(for: broadcastKey)
            let attributes = OrderAttributes(pushwrenKey: broadcastKey, orderNumber: "Everyone")
            let content = ActivityContent(state: OrderAttributes.ContentState(status: "Waiting for the first update", etaMinutes: 0), staleDate: nil)
            _ = try Activity.request(attributes: attributes, content: content, pushType: .channel(channel))
            message = "Following \(broadcastKey). Every broadcast update reaches this activity."
        } catch {
            message = "Couldn't follow \(broadcastKey): \(error)"
        }
    }
}
