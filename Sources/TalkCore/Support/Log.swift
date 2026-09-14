import Foundation

#if canImport(os)
import os
#endif

/// Structured logging facade.
///
/// One facade rather than raw `os.Logger` call sites, for two reasons: the core has to
/// keep compiling where `os` does not exist, and routing every message through here makes
/// the redaction rule enforceable in one place.
///
/// **Never pass through this API:** app passwords, `Authorization` headers, login-flow
/// poll tokens, or message bodies. Message bodies may only be logged via
/// ``LogCategory/sensitive(_:)``, which is silent unless developer mode is on.
enum Log {
    static let subsystem = "app.kvidr.mac"

    static let auth = LogCategory("auth")
    static let api = LogCategory("api")
    static let sync = LogCategory("sync")
    static let chat = LogCategory("chat")
    static let persistence = LogCategory("persistence")
    static let notification = LogCategory("notification")
    static let ui = LogCategory("ui")

    /// Developer mode unlocks verbose logging that may include message content.
    /// Off by default, and only settable from the Advanced settings pane in a DEBUG build.
    nonisolated(unsafe) static var isDeveloperModeEnabled = false

    /// Where `os` doesn't exist (Linux CI), logging goes to stderr — which would bury the
    /// test output. Opt in with `TALK_LOG=1`.
    static let isStderrLoggingEnabled =
        ProcessInfo.processInfo.environment["TALK_LOG"] != nil
}

struct LogCategory: Sendable {
    let name: String

    #if canImport(os)
    private let logger: Logger
    #endif

    init(_ name: String) {
        self.name = name
        #if canImport(os)
        self.logger = Logger(subsystem: Log.subsystem, category: name)
        #endif
    }

    func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
    func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
    func notice(_ message: @autoclosure () -> String) { emit(.notice, message()) }
    func warning(_ message: @autoclosure () -> String) { emit(.warning, message()) }
    func error(_ message: @autoclosure () -> String) { emit(.error, message()) }

    /// Logging that may contain user content. Silent unless developer mode is enabled,
    /// and marked private to the logging system even then.
    func sensitive(_ message: @autoclosure () -> String) {
        guard Log.isDeveloperModeEnabled else { return }
        // Evaluated into a local first: os_log's interpolation takes its arguments
        // escaping, which a non-escaping autoclosure parameter can't be passed to.
        let text = message()
        #if canImport(os)
        logger.debug("\(text, privacy: .private)")
        #else
        guard Log.isStderrLoggingEnabled else { return }
        FileHandle.standardError.write(Data("[\(name)] \(text)\n".utf8))
        #endif
    }

    private func emit(_ level: LogLevel, _ message: String) {
        #if canImport(os)
        // Explicitly public: the rule above guarantees nothing secret reaches this call.
        logger.log(level: level.osLevel, "\(message, privacy: .public)")
        #else
        guard Log.isStderrLoggingEnabled else { return }
        FileHandle.standardError.write(Data("[\(level.label)] [\(name)] \(message)\n".utf8))
        #endif
    }

    private enum LogLevel {
        case debug, info, notice, warning, error

        var label: String {
            switch self {
            case .debug: "debug"
            case .info: "info"
            case .notice: "notice"
            case .warning: "warning"
            case .error: "error"
            }
        }

        #if canImport(os)
        var osLevel: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .notice: .default
            case .warning: .error
            case .error: .fault
            }
        }
        #endif
    }
}
