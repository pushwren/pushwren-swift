import Pushwren
import SwiftUI

@main
struct PushwrenSampleApp: App {
    // The two lines a developer adds: the adaptor, and configure.
    #if os(macOS)
    @NSApplicationDelegateAdaptor(PushwrenAppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(PushwrenAppDelegate.self) var appDelegate
    #endif

    init() {
        Pushwren.logLevel = .debug
        Pushwren.configure(appKey: Bundle.main.object(forInfoDictionaryKey: "PushwrenAppKey") as? String ?? "")
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
