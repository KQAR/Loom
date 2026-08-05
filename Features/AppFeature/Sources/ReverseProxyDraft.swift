import Foundation
import LoomSharedModels

/// What the console's Add-endpoint form has typed so far, and what is wrong with it.
///
/// Validation is live rather than on submit because both fields fail in ways that are
/// cheap to state and expensive to discover late: a bare host (`api.example.com`) parses
/// as a path and would forward nowhere, and a port outside 1…65535 can never bind. The
/// engine checks both again on the way in — it is the authority, and it is what an
/// agent's `create_reverse_proxy` hits — so this exists only to say so *while* typing
/// instead of after a round trip.
///
/// A value type with no view in it, so the rules are testable: the interesting cases
/// (bare host, query on an origin, port 0 typed by hand vs left blank) are ones nobody
/// reproduces by clicking through a preview.
struct ReverseProxyDraft: Equatable {
    /// Raw field text. Kept as typed — trimming happens where it is read, so the
    /// message a half-typed value produces doesn't jump around as spaces come and go.
    var port = ""
    var upstream = ""
    var keepHostHeader = false

    private var trimmedPort: String { port.trimmingCharacters(in: .whitespaces) }
    private var trimmedUpstream: String { upstream.trimmingCharacters(in: .whitespaces) }

    /// Blank is legitimate and means "any free port" — the OS picks, and the card shows
    /// which one it got. So an empty field is not a problem to report.
    var portProblem: String? {
        guard !trimmedPort.isEmpty else { return nil }
        guard let value = Int(trimmedPort), String(value) == trimmedPort else {
            return "Port must be a number."
        }
        guard (1 ... 65535).contains(value) else { return "Port must be 1–65535." }
        return nil
    }

    /// The engine's own validator, reused rather than re-implemented: it is the same
    /// function `create_reverse_proxy` calls, and its message already names what to fix
    /// (missing scheme, no host, a query on an origin). A second copy of these rules
    /// would be a second answer to "is this upstream usable".
    var upstreamProblem: String? {
        guard !trimmedUpstream.isEmpty else { return nil }
        do {
            _ = try ReverseProxyEndpoint.normalizedUpstream(trimmedUpstream)
            return nil
        } catch let error as ProxyControlError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    /// The upstream is required; the port isn't. Both must be free of problems.
    var canSubmit: Bool {
        !trimmedUpstream.isEmpty && upstreamProblem == nil && portProblem == nil
    }

    /// `0` is what the engine reads as "any free port", and a blank field means exactly
    /// that. A hand-typed `0` is refused by `portProblem` first, so the two can't be
    /// confused here.
    var submittedPort: Int { Int(trimmedPort) ?? 0 }

    var submittedUpstream: String { trimmedUpstream }
}
