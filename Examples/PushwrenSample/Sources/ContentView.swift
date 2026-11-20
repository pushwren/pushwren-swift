import Pushwren
import SwiftUI

/// Shows what Pushwren knows about this device, with buttons for the calls an app makes.
struct ContentView: View {
    @State private var diagnostics = "Starting…"
    @State private var permission = ""
    @State private var lastOpen = "none yet"

    var body: some View {
        NavigationStack {
            Form {
                Section("This device") {
                    Text(diagnostics)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy device ID") { copy(Pushwren.deviceID ?? "") }
                }
                Section("Last opened notification") {
                    Text(lastOpen)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("Try it") {
                    Button("Ask for permission") {
                        Task {
                            let status = try? await Pushwren.requestPermission()
                            permission = status?.rawValue ?? "error"
                            await refresh()
                        }
                    }
                    if !permission.isEmpty { Text("Permission: \(permission)") }
                    Button("Set user u_demo") { Pushwren.setUserID("u_demo"); later() }
                    Button("Clear user") { Pushwren.clearUserID(); later() }
                    Button("Add tag beta") { Pushwren.addTags(["beta"]); later() }
                    Button("Remove tag beta") { Pushwren.removeTags(["beta"]); later() }
                }
            }
            .navigationTitle("Pushwren Sample")
            .toolbar { Button("Refresh") { Task { await refresh() } } }
        }
        .task {
            // Taps arrive here, including the one that launched the app.
            for await open in Pushwren.opens {
                let data = String(data: open.dataJSON, encoding: .utf8) ?? "{}"
                lastOpen = "\(open.notificationID ?? "not from Pushwren")\n\(data)"
            }
        }
        .task {
            // Refresh a few times while the first registration happens.
            for _ in 0..<5 {
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func refresh() async { diagnostics = "\(await Pushwren.diagnostics())" }

    /// Changes are debounced for a second before they go out.
    private func later() {
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await refresh()
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
