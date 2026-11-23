import Foundation
import os

/// How much the SDK writes to the unified log. Errors and info (registrations, dropped changes) are on by default.
public enum LogLevel: Int, Sendable, Comparable {
    case off, error, info, debug

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Logging through os.Logger, subsystem "com.pushwren.sdk". Device tokens are never logged whole.
enum Log {
    /// Info by default (0.3.0): "Registered device…" is what tells a developer push is working.
    static let defaultLevel = LogLevel.info
    private static let state = OSAllocatedUnfairLock(initialState: defaultLevel)
    private static let logger = Logger(subsystem: "com.pushwren.sdk", category: "Pushwren")

    static var level: LogLevel {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    static func error(_ message: @autoclosure () -> String) {
        guard level >= .error else { return }
        let text = message()
        logger.error("\(text, privacy: .public)")
    }

    static func info(_ message: @autoclosure () -> String) {
        guard level >= .info else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard level >= .debug else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }

    /// The last 8 characters of a device token: all a log line may show.
    static func tail(_ token: String) -> String { "…" + token.suffix(8) }
}
