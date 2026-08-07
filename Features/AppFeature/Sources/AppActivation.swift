import AppKit
import Foundation

/// Every time Loom becomes the active app.
///
/// The re-read hung off the audit stream (see `AuditFeature.liveStreamedTools`)
/// covers the writer that is an *agent*. It cannot cover the other one: a human in
/// another app. CA trust is the clearest case — Loom prints a
/// `sudo security add-trusted-cert` line for machine-wide trust and the human runs
/// it in Terminal, or they revoke it later in Keychain Access. Neither goes through
/// Loom, neither is a write tool, and the panel's "Not trusted" row kept saying so
/// afterwards. Helper approval in System Settings is the same shape.
///
/// Coming back to Loom is the moment that matters, and it is a documented
/// notification. A `com.apple.security.trustsettingschanged` Darwin notification is
/// the more direct-sounding answer and is deliberately **not** used: the constant is
/// not in the public SDK, and confirming that Security.framework actually posts it
/// needs a real trust change behind an authorization prompt — i.e. it would be a
/// guess, and a silent one when wrong. Activation is neither.
enum AppActivation {
    static func events() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                // No queue: deliver inline on the posting thread. AppKit posts this
                // on the main thread already, and hopping would only add a turn of
                // the run loop between "the human came back" and the re-read.
                queue: nil
            ) { _ in continuation.yield(()) }
            let teardown = Teardown(observer: observer)
            continuation.onTermination = { _ in teardown.run() }
        }
    }

    /// Carries the observer token across the `@Sendable` boundary of
    /// `onTermination`. `NSObjectProtocol` has no `Sendable` conformance and the
    /// token is opaque; it is only ever handed straight back to the notification
    /// centre, exactly once.
    private final class Teardown: @unchecked Sendable {
        private let observer: NSObjectProtocol
        init(observer: NSObjectProtocol) { self.observer = observer }
        func run() { NotificationCenter.default.removeObserver(observer) }
    }
}
