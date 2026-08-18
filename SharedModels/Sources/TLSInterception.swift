import Foundation

/// Snapshot of the man-in-the-middle root CA's state, surfaced to the human
/// (status-bar fault card) and to the agent (`get_certificate_status`).
public struct CertificateStatus: Equatable, Codable, Sendable {
    /// A root CA exists (generated on first launch and persisted).
    public var isGenerated: Bool
    /// Best-effort: the CA is present as a trusted anchor in a system/user trust
    /// store. HTTPS interception only works for clients that trust this anchor.
    public var isTrusted: Bool
    public var commonName: String?
    /// Colon-separated uppercase SHA-256 of the CA certificate (DER).
    public var sha256Fingerprint: String?
    public var notAfter: Date?
    /// Filesystem path the CA PEM was last exported to, if any.
    public var exportedPEMPath: String?

    public init(
        isGenerated: Bool,
        isTrusted: Bool,
        commonName: String? = nil,
        sha256Fingerprint: String? = nil,
        notAfter: Date? = nil,
        exportedPEMPath: String? = nil
    ) {
        self.isGenerated = isGenerated
        self.isTrusted = isTrusted
        self.commonName = commonName
        self.sha256Fingerprint = sha256Fingerprint
        self.notAfter = notAfter
        self.exportedPEMPath = exportedPEMPath
    }

    public static let notGenerated = CertificateStatus(isGenerated: false, isTrusted: false)

    /// The setup stage the human is at, so the UI can drive one clear next step.
    public var trustState: CertificateTrustState {
        if !isGenerated { return .notGenerated }
        return isTrusted ? .trusted : .notTrusted
    }
}

/// Where the root CA is in the "generate → trust → decrypt" journey. Drives the
/// certificate card's icon, copy, and which action is offered next.
public enum CertificateTrustState: Equatable, Sendable {
    /// No CA yet (generated lazily on first interception).
    case notGenerated
    /// CA exists but isn't trusted for TLS, so decryption would fail.
    case notTrusted
    /// Trusted system-wide — interception works.
    case trusted

    public var isReady: Bool { self == .trusted }

    public var title: String {
        switch self {
        case .notGenerated: return "Certificate not generated"
        case .notTrusted: return "Trust required"
        case .trusted: return "CA trusted"
        }
    }

    public var message: String {
        switch self {
        case .notGenerated:
            return "Loom's root CA is created the first time you intercept. Turn SSL on to generate it."
        case .notTrusted:
            return "The root CA exists but macOS hasn't trusted it for TLS. Install & trust it to decrypt HTTPS."
        case .trusted:
            return "HTTPS interception is ready for hosts in scope."
        }
    }

    public var systemImageName: String {
        switch self {
        case .notGenerated: return "xmark.seal"
        case .notTrusted: return "exclamationmark.triangle.fill"
        case .trusted: return "checkmark.seal.fill"
        }
    }
}

/// Why a connection was relayed byte-for-byte instead of decrypted.
///
/// Every case means the same thing to a read surface — no request, no response,
/// no rules, no breakpoints, nothing to replay — so the *reason* is the only
/// thing that distinguishes "one click from being captured" from "asked for" from
/// "Loom couldn't". Ordered roughly by how actionable it is.
public enum TunnelReason: String, Codable, Sendable, CaseIterable {
    /// HTTPS interception is switched off entirely.
    case interceptionDisabled
    /// Interception is on, but no `include` glob covers this host.
    case notInScope
    /// An `exclude` glob covers this host — a deliberate pass-through.
    case excluded
    /// In scope, but there is no root CA to mint a leaf from.
    case noCertificateAuthority
    /// In scope with a CA, and minting the leaf failed. Fail-open: a host that
    /// stops loading would be worse than one Loom can't read.
    case leafMintFailed
    /// The tunnel's first bytes were neither a TLS record, an HTTP request line,
    /// nor the h2c connection preface — SSH, SMTP, a hand-rolled binary protocol —
    /// or the connection is server-first and said nothing before the sniff deadline.
    /// Being in the SSL scope does not make these readable.
    case notTLSOrHTTP
    /// Client-facing TLS did not complete after Loom began interception.
    ///
    /// The one reason on this list where the traffic did not merely go *unread*: it
    /// did not happen. `clientTLS.lastFailureCode` / `lastFailureAlert` name the
    /// alert when there was one: `certificate_unknown` is inconclusive (also sent
    /// by apps that ignore user CAs), not proof the leaf is invalid or that the
    /// host is pinned. An include cannot fix it; the remedy is pass-through or
    /// making that specific client trust Loom's CA.
    case clientHandshakeFailed
    /// The decrypted stream broke a protocol rule Loom's codec enforces, so the
    /// exchange could not be read and the connection was closed.
    ///
    /// The measured case is HTTP/2: `SETTINGS_MAX_HEADER_LIST_SIZE` starts at
    /// SwiftNIO's 16 KB default on a brand-new connection — the decoder only picks
    /// up a larger advertised value once the peer acknowledges the SETTINGS frame
    /// (RFC 9113 §6.5.3) — so a client whose *first* request carries a field
    /// section over 16 KB (an app with grown session cookies) has it rejected.
    /// Like `clientHandshakeFailed`, the request did not happen: this is a broken
    /// page, not an opaque one. `detail` names the codec error.
    case protocolError
}

/// One host Loom saw HTTPS (or opaque TCP) activity to and relayed without
/// reading, collapsed across every connection to it.
///
/// Aggregated per `host:port` rather than recorded per connection: the question
/// this answers is "what is Loom not showing me, and should it be", which one row
/// per origin answers and fifty rows per page load obscures.
public struct TunneledHost: Equatable, Codable, Sendable, Identifiable {
    public var host: String
    public var port: Int
    /// Connections observed for the current reason. For a client TLS failure this
    /// equals `clientTLS.failureCount`; successes are counted separately.
    public var connections: Int
    public var firstSeen: Date
    public var lastSeen: Date
    /// The most recent reason. It can change — a host moves from `.notInScope` to
    /// `.notTLSOrHTTP` the moment someone intercepts it and the bytes turn out not
    /// to be TLS at all — and the latest one is the one worth acting on.
    public var reason: TunnelReason
    /// What Loom saw, when the reason alone doesn't say enough to act on — the
    /// handshake error for `.clientHandshakeFailed`, nil for every other reason.
    ///
    /// It is a field rather than a log line because both readers need the underlying
    /// evidence without scraping Console output.
    public var detail: String?
    /// Client-facing handshake evidence. Present only after Loom attempted TLS
    /// interception and the client failed at least once.
    public var clientTLS: ClientTLS?

    public init(
        host: String, port: Int, connections: Int = 1,
        firstSeen: Date, lastSeen: Date, reason: TunnelReason, detail: String? = nil,
        clientTLS: ClientTLS? = nil
    ) {
        self.host = host
        self.port = port
        self.connections = connections
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.reason = reason
        self.detail = detail
        self.clientTLS = clientTLS
    }

    public var id: String { "\(host):\(port)" }

    /// Whether bringing this host into the SSL scope would actually make it
    /// readable. `false` for the two cases an include entry cannot fix, so a
    /// surface can offer the one-click action only where it does something.
    public var interceptable: Bool {
        switch reason {
        case .interceptionDisabled, .notInScope, .excluded: true
        case .noCertificateAuthority, .leafMintFailed, .notTLSOrHTTP, .clientHandshakeFailed,
             .protocolError: false
        }
    }

    /// Did the client's traffic fail, rather than merely go unread?
    ///
    /// Every other reason on this list is a pass-through: the request reached the
    /// origin and Loom simply didn't read it. A rejected handshake is the one where
    /// the request never happened, so a surface that treats "unread" as benign has
    /// to tell this one apart.
    public var brokeTheClient: Bool {
        if reason == .protocolError { return true }
        guard reason == .clientHandshakeFailed else { return false }
        return true
    }
}

/// The tunnelled-host list plus what the cap dropped.
///
/// `evicted` exists because a bounded collection that truncates silently reads as
/// "this is everything" — the same rule every other capped collection in Loom
/// follows. Entries go least-recently-active first, so a non-zero count means old
/// origins, not missing recent ones.
public struct TunneledHostReport: Equatable, Codable, Sendable {
    public var hosts: [TunneledHost]
    public var evicted: Int
    /// Successful handshakes discarded from the hidden pre-failure cache.
    /// Non-nil means a later host-level mixed verdict may be an under-count.
    public var clientSuccessesEvicted: Int?

    public init(
        hosts: [TunneledHost] = [],
        evicted: Int = 0,
        clientSuccessesEvicted: Int? = nil
    ) {
        self.hosts = hosts
        self.evicted = evicted
        self.clientSuccessesEvicted = clientSuccessesEvicted
    }
}

/// What `SSLScope.intercept(host:)` had to change, and what it could not.
public struct InterceptOutcome: Equatable, Codable, Sendable {
    /// An `include` glob already covered the host, so the list is unchanged.
    public var alreadyIncluded = false
    /// Interception was off and this turned it on — a machine-wide change the
    /// caller did not literally ask for, so it is reported rather than assumed.
    public var enabledInterception = false
    /// Exact `exclude` entries for this host that were dropped.
    public var removedExcludes: [String] = []
    /// A wildcard `exclude` that still shadows the host: it is *not* intercepted
    /// despite the include. Whoever wrote that glob has to be the one to narrow it.
    public var shadowedByExclude: String?
    /// Live relayed tunnels to this host that were **closed**, so the client
    /// reconnects into an intercepted connection instead of keeping an opaque one.
    ///
    /// Reported rather than done silently: a scope write that also ends N live
    /// connections is a consequence the caller should learn about — a request in
    /// flight on one of them is retried by the client or fails. Zero is the ordinary
    /// case, meaning nothing was open to that host.
    public var closedTunnels = 0

    public init() {}

    /// Is the host decrypted as a result of this call?
    public var effective: Bool { shadowedByExclude == nil }
}

/// What `SSLScope.stopIntercepting(host:)` had to change.
///
/// Separate from `InterceptOutcome` rather than shared: the two calls fail in
/// different directions, and a struct carrying both sets of fields would have half
/// of them meaningless at every call site.
public struct StopInterceptOutcome: Equatable, Codable, Sendable {
    /// Exact `include` entries dropped.
    public var removedIncludes: [String] = []
    /// An `include` *glob* still covers the host, so removing entries could not
    /// finish the job on its own.
    public var shadowedByInclude: String?
    /// An `exclude` was added because of that glob. The host is passed through, but
    /// by a standing carve-out rather than by simply not being named.
    public var addedExclude = false

    public init() {}

    /// Is the host passed through as a result of this call? Always true — the two
    /// mechanisms between them cover every case — and stated so a caller reports the
    /// outcome the same way it reports `intercept`'s.
    public var effective: Bool { true }
}

/// Which hosts Loom decrypts (MITM) vs. blind-tunnels. A host is intercepted
/// only when interception is `enabled`, it matches an `include` glob, and it
/// matches no `exclude` glob. `exclude` doubles as the pinned / pass-through
/// list: cert-pinned hosts belong here so they keep working untouched.
public struct SSLScope: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var include: [String]
    public var exclude: [String]

    public init(enabled: Bool = false, include: [String] = [], exclude: [String] = []) {
        self.enabled = enabled
        self.include = include
        self.exclude = exclude
    }

    public static let disabled = SSLScope()

    /// Should the given host be MITM-decrypted under this scope?
    public func shouldIntercept(host: String) -> Bool {
        passthroughReason(host: host) == nil
    }

    /// Why this scope would *not* decrypt `host` — `nil` when it would.
    ///
    /// The same decision as `shouldIntercept`, stated so it can be reported. A
    /// blind-tunnelled host is invisible to every read surface, and "not in the
    /// scope" and "explicitly excluded" need different words: the first is one
    /// click away from being captured, the second was asked for.
    public func passthroughReason(host: String) -> TunnelReason? {
        guard enabled else { return .interceptionDisabled }
        guard include.contains(where: { Glob.matches($0, host) }) else { return .notInScope }
        return excludeGlob(matching: host) == nil ? nil : .excluded
    }

    /// The first `exclude` glob that covers `host`, if any. Named separately from
    /// `passthroughReason` because a caller trying to *undo* an exclusion needs the
    /// pattern, not just the verdict.
    public func excludeGlob(matching host: String) -> String? {
        exclude.first { Glob.matches($0, host) }
    }

    /// Bring `host` into the intercepted set, and say honestly what that took.
    ///
    /// Three things can stand between "the caller named a host" and "the host is
    /// decrypted", and adding an include entry only fixes one of them — so this
    /// turns interception on when it was off, drops an *exact* exclude for the
    /// host, and reports a wildcard exclude it cannot beat. An include that
    /// silently loses to `exclude` is precisely the invisible-failure shape the
    /// tunnelled-host surface exists to remove.
    public mutating func intercept(host: String) -> InterceptOutcome {
        var outcome = InterceptOutcome()

        if !enabled {
            enabled = true
            outcome.enabledInterception = true
        }
        // An exact exclude for this host is a previous "leave it alone" that the
        // caller is now reversing; a glob is someone else's rule, so it stands.
        let exact = exclude.filter { $0.lowercased() == host.lowercased() }
        if !exact.isEmpty {
            exclude.removeAll { $0.lowercased() == host.lowercased() }
            outcome.removedExcludes = exact
        }
        if include.contains(where: { Glob.matches($0, host) }) {
            outcome.alreadyIncluded = true
        } else {
            include.append(host)
        }
        // Re-read the *resulting* scope rather than reasoning about it: this is the
        // one answer the caller acts on, and deriving it twice is how the two
        // disagree.
        outcome.shadowedByExclude = excludeGlob(matching: host)
        return outcome
    }

    /// Stop decrypting `host`, and say what that took.
    ///
    /// The inverse of `intercept(host:)`, and under a whitelist scope the inverse is
    /// **removing the include entry**, not adding an exclude. Three reasons, and the
    /// first is the one that bites: an exclude is a standing carve-out that outlives
    /// the entry it was answering, so a later `intercept(host:)` would appear to
    /// succeed and change nothing. It is also redundant — an un-named host is already
    /// relayed — and it is a second row on the console describing a state the first
    /// list already describes by omission. Dropping the entry returns the host to
    /// where every un-named host already is: observed, tunnelled, one click from
    /// being decrypted again.
    ///
    /// An `exclude` is still added in the one case where removing cannot finish the
    /// job: the host was covered by a *glob* (`*`, `*.corp`) that belongs to some
    /// broader intent, so narrowing it is not this call's business.
    ///
    /// `host` may itself be a glob — the request table's "Pass Through `*.parent`"
    /// item. Matching that string as a hostname never finds the literal include
    /// entries it covers (`api.example.com` is not equal to `*.example.com`), so
    /// those have to be dropped explicitly. A wider include glob still standing
    /// (`*`) takes the exclude path above.
    public mutating func stopIntercepting(host: String) -> StopInterceptOutcome {
        var outcome = StopInterceptOutcome()
        let exact = include.filter { $0.lowercased() == host.lowercased() }
        if !exact.isEmpty {
            include.removeAll { $0.lowercased() == host.lowercased() }
            outcome.removedIncludes = exact
        }
        if !Glob.pattern(for: host).isLiteral {
            let covered = include.filter { Glob.matches(host, $0) }
            if !covered.isEmpty {
                include.removeAll { Glob.matches(host, $0) }
                outcome.removedIncludes.append(contentsOf: covered)
            }
        }
        // Re-read rather than reason about it, for the same reason `intercept` does.
        if let glob = include.first(where: { Glob.matches($0, host) }) {
            outcome.shadowedByInclude = glob
            if !exclude.contains(where: { $0.lowercased() == host.lowercased() }) {
                exclude.append(host)
                outcome.addedExclude = true
            }
        }
        return outcome
    }

    /// Case-insensitive glob match — **moved to `Glob`**, which is what it always was:
    /// three of this function's callers were never about the SSL scope and two were
    /// never about hosts (a rule matches a whole URL through it). Kept as a forwarder
    /// rather than deleted because `LoomSharedModels` is a public SPM product.
    @available(*, deprecated, message: "Use Glob.matches(_:_:), or Glob.Pattern when matching many strings against one pattern.")
    public static func matches(pattern: String, host: String) -> Bool {
        Glob.matches(pattern, host)
    }
}

/// The HTTPS-interception surface of the engine — certificate state and the
/// SSL-proxying scope. Composed into `ProxyControlling` so both the MCP server
/// and the TCA client reach it through the one shared engine.
public protocol TLSInterceptControlling: Sendable {
    func certificateStatus() async -> CertificateStatus
    /// Write the root CA (PEM) to disk so the human can trust it; returns the path.
    func exportCACertificate() async throws -> URL
    func sslScope() async -> SSLScope
    func setSSLScope(_ scope: SSLScope) async
    /// Hosts Loom relayed without reading, newest activity first, with the ones
    /// the current scope would now decrypt already filtered out.
    ///
    /// This is the discoverability half of a whitelist scope: with an empty
    /// `include`, an unrecorded pass-through is indistinguishable from a client
    /// that never ran, so "there was HTTPS here and Loom didn't read it" has to be
    /// a fact a surface can ask for rather than one only `os_log` holds.
    func tunneledHosts() async -> TunneledHostReport
    /// Bring one host into the SSL scope — the one-click action behind a tunnelled
    /// host — and report what it took. Atomic in the engine, because the read /
    /// modify / write a caller would otherwise do can lose a concurrent edit.
    func interceptHost(_ host: String) async -> InterceptOutcome
    /// Stop decrypting one host — the inverse of `interceptHost`, behind a "Pass
    /// Through" action — and report what it took. Atomic for the same reason: the
    /// console used to read the whole scope, edit it and write it back, so a
    /// concurrent agent `interceptHost` landing in that window was silently
    /// clobbered. `SSLScope.stopIntercepting` has the whitelist semantics.
    func stopInterceptingHost(_ host: String) async -> StopInterceptOutcome
}
