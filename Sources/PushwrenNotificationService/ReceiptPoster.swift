import Foundation

/// Posts a push's delivery receipt (`_r`) back to Pushwren with its notification ID (`_h`).
/// Best effort: one try, any answer but 204 is dropped, nothing is kept for later.
struct ReceiptPoster: Sendable {
    static let timeout: TimeInterval = 5

    let session: URLSession
    /// Where an `l` (local) code posts. nil outside tests, so an `l` code posts nothing.
    let localBaseURL: URL?

    /// The POST for this push, or nil when there is nothing valid to post.
    func request(for userInfo: [AnyHashable: Any]) -> URLRequest? {
        guard let notificationID = userInfo["_h"] as? String, Self.isNotificationID(notificationID),
              let receipt = userInfo["_r"] as? String, Self.isReceipt(receipt),
              let base = baseURL(for: receipt)
        else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("v1/receipts"), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both values are checked above to need no escaping.
        request.httpBody = Data(#"{"notificationId":"\#(notificationID)","receipt":"\#(receipt)"}"#.utf8)
        return request
    }

    /// Sends it; `done` runs once when it has an answer, fails or times out.
    func post(_ request: URLRequest, done: @escaping @Sendable () -> Void) {
        session.dataTask(with: request) { _, _, _ in done() }.resume()
    }

    /// A code's first character names the server that signed it.
    private func baseURL(for receipt: String) -> URL? {
        switch receipt.first {
        case "p": URL(string: "https://api.pushwren.com")
        case "d": URL(string: "https://api.dev.pushwren.com")
        case "l": localBaseURL
        default: nil
        }
    }

    /// `ntf_` and 26 Crockford base32 characters, as the server's NOTIFICATION_ID_RE.
    static func isNotificationID(_ s: String) -> Bool {
        guard s.hasPrefix("ntf_") else { return false }
        let id = s.utf8.dropFirst(4)
        return id.count == 26 && id.allSatisfy { c in
            (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
                || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")
                    && c != UInt8(ascii: "I") && c != UInt8(ascii: "L") && c != UInt8(ascii: "O") && c != UInt8(ascii: "U"))
        }
    }

    /// 1 to 200 base64url characters, as the server's RECEIPT_RE.
    static func isReceipt(_ s: String) -> Bool {
        (1...200).contains(s.utf8.count) && s.utf8.allSatisfy { c in
            (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
                || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
                || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z"))
                || c == UInt8(ascii: "-") || c == UInt8(ascii: "_")
        }
    }
}
