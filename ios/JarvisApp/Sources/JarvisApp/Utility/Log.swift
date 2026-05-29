import Foundation
import os.log

/// Lightweight category-tagged logging. Uses Apple's unified logging
/// (os.Logger) for release builds; falls back to console output in DEBUG.
/// Replaces ad-hoc `print(...)` calls scattered through services.
enum Log {

    enum Category: String {
        case ws         = "WS"
        case outbox     = "Outbox"
        case cache      = "Cache"
        case speech     = "Speech"
        case watch      = "Watch"
        case health     = "Health"
        case location   = "Location"
        case proactive  = "Proactive"
        case voice      = "Voice"
        case app        = "App"
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.vasechko.jarvis"

    private static func logger(for category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        #if DEBUG
        let msg = message()
        logger(for: category).debug("\(msg, privacy: .public)")
        print("[\(category.rawValue)] \(msg)")
        #endif
    }

    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        let msg = message()
        logger(for: category).info("\(msg, privacy: .public)")
        #if DEBUG
        print("[\(category.rawValue)] \(msg)")
        #endif
    }

    static func warn(_ category: Category, _ message: @autoclosure () -> String) {
        let msg = message()
        logger(for: category).warning("\(msg, privacy: .public)")
        #if DEBUG
        print("⚠️ [\(category.rawValue)] \(msg)")
        #endif
    }

    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        let msg = message()
        logger(for: category).error("\(msg, privacy: .public)")
        #if DEBUG
        print("❌ [\(category.rawValue)] \(msg)")
        #endif
    }
}
