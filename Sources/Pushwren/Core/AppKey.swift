import Foundation

/// A publishable key, which also says which Pushwren API to talk to: "pk_dev_" keys belong to the
/// dev environment, "pk_live_" keys to production. Secret keys ("sk_") never belong in an app.
struct AppKey: Sendable, Equatable {
    let raw: String
    let apiBaseURL: URL

    init?(_ raw: String) {
        guard raw.range(of: "^pk_(dev|live)_[0-9A-Za-z]{32}$", options: .regularExpression) != nil else { return nil }
        self.raw = raw
        self.apiBaseURL = URL(string: raw.hasPrefix("pk_dev_") ? "https://api.dev.pushwren.com" : "https://api.pushwren.com")!
    }
}
