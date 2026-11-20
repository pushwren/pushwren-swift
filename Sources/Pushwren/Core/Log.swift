import Foundation
import os

/// How much the SDK writes to the unified log. Errors are on by default.
public enum LogLevel: Int, Sendable, Comparable {
    case off, error, info, debug

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Logging through os.Logger, subsystem "com.pushwren.sdk". Device tokens are never logged whole.
enum Log {
    private static let state = OSAllocatedUnfairLock(initialState: LogLevel.error)
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
