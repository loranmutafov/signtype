import os

/// Unified logging. Watch with:
///   log stream --predicate 'subsystem == "dev.loran.signtype"' --level debug
enum Log {
    static let subsystem = "dev.loran.signtype"
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let session = Logger(subsystem: subsystem, category: "session")
}
