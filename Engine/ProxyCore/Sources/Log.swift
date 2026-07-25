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
    /// The write-action trail. Separate from `store` because a gap here is a gap in
    /// the human's record of what the agent did, not just a lost capture.
    static let audit = Logger(subsystem: subsystem, category: "audit")
    /// Rule evaluation/application — a rule that silently fails to apply makes an
    /// agent believe traffic was mocked or re-mapped when it wasn't.
    static let rules = Logger(subsystem: subsystem, category: "rules")
}
