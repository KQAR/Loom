import os

/// Module-wide logging. ProxyCore previously had none, so failures that fail
/// *open* (a corrupt CA silently disabling interception, a persistence write
/// dropping on the floor) were invisible — untenable for a tool whose operator
/// is an AI agent that can't watch a console. Use these categories so `log
/// stream --predicate 'subsystem == "com.loom"'` can filter by area.
enum Log {
    private static let subsystem = "com.loom"

    static let proxy = Logger(subsystem: subsystem, category: "proxy")
    static let tls = Logger(subsystem: subsystem, category: "tls")
    static let forward = Logger(subsystem: subsystem, category: "forward")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let ws = Logger(subsystem: subsystem, category: "websocket")
}
