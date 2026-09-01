import Foundation
import Testing

@testable import LoomSharedModels

/// `error.localizedDescription` is what eleven call sites across the app show the
/// operator — the phone popover, replay, rules, breakpoints, the reverse-proxy
/// draft. Without `LocalizedError`, Foundation renders a plain `Error` as "The
/// operation couldn't be completed. (LoomSharedModels.ProxyControlError error 15.)",
/// so `message` was a property nobody ever saw.
@Suite("ProxyControlError is what the operator reads")
struct ProxyControlErrorTests {
    @Test func localizedDescription_isTheMessage() {
        let error = ProxyControlError.listenerUnavailable(
            "127.0.0.1:9090 is already in use — another proxy or a dev server is listening there."
        )
        #expect(error.localizedDescription == error.message)
        #expect(error.localizedDescription.contains("9090"))
    }

    /// The failure mode this guards against, stated as a test rather than as a
    /// comment: a case number reaching a human.
    @Test func localizedDescription_neverRendersAsACaseNumber() {
        let errors: [ProxyControlError] = [
            .listenerUnavailable("port taken"),
            .invalidURL("http://"),
            .replayFailed("upstream refused"),
            .phoneOnboardingUnavailable("no LAN IPv4"),
            .flowNotFound(UUID()),
        ]
        for error in errors {
            let described = error.localizedDescription
            #expect(!described.contains("ProxyControlError error"), "case number leaked: \(described)")
            #expect(!described.contains("couldn\u{2019}t be completed"), "Foundation placeholder: \(described)")
        }
    }
}
