import Foundation

/// A client identity Loom presents when an origin asks for one (mutual TLS).
///
/// Why this has to exist: with mTLS, the *server* demands a certificate during the
/// handshake. Loom's upstream leg is its own TLS connection, so a target requiring
/// a client certificate doesn't just lose a header — the handshake fails outright
/// and the exchange cannot be captured at all. Unlike cert pinning (which is the
/// origin deliberately refusing a proxy, and correctly stays unfixable), this is a
/// case where the operator *has* the credential and only needs Loom to use it.
///
/// PKCS#12 rather than separate PEMs because that is the artifact an issuer hands
/// out and the format macOS's Keychain exports. The passphrase lives next to the
/// blob on purpose: both sit in one 0600 file inside the 0700 Application Support
/// directory, and splitting them across two files of identical permissions would
/// move the secret without protecting it.
public struct ClientCertificate: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    /// Hosts this identity is presented to, as a glob (`api.corp.example`,
    /// `*.corp.example`) matched with the same semantics as the SSL scope.
    ///
    /// Scoped rather than global because presenting a client certificate is not
    /// neutral: it identifies the operator to whoever asked, so an identity meant
    /// for one internal API must not be offered to every host that requests one.
    public var hostPattern: String
    /// PKCS#12 (`.p12` / `.pfx`) bytes holding the leaf, its chain and the key.
    public var pkcs12: Data
    /// Passphrase protecting `pkcs12`. Empty string for an unprotected bundle.
    public var passphrase: String
    /// Operator-facing name. Free text; defaults to the host pattern when omitted.
    public var label: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        hostPattern: String,
        pkcs12: Data,
        passphrase: String = "",
        label: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.hostPattern = hostPattern
        self.pkcs12 = pkcs12
        self.passphrase = passphrase
        self.label = label.isEmpty ? hostPattern : label
        self.isEnabled = isEnabled
    }
}

/// What a *reader* of the client-certificate list is allowed to see.
///
/// Deliberately not `ClientCertificate`: that type carries a private key and its
/// passphrase, and the two readers here are an MCP tool response and a UI list.
/// A read surface that can echo back the credential is one prompt-injected agent
/// (or one pasted transcript) away from leaking it, and there is no debugging
/// question that needs the bytes returned.
public struct ClientCertificateSummary: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var hostPattern: String
    public var label: String
    public var isEnabled: Bool
    /// Leaf subject, parsed from the bundle. Nil when the bundle could not be read
    /// (wrong passphrase, or not a PKCS#12) — which is exactly the state an
    /// operator needs to see rather than discover as a handshake failure later.
    public var subject: String?
    /// Leaf expiry. An expired client certificate fails the handshake the same way
    /// a missing one does, so it is surfaced instead of inferred.
    public var notAfter: Date?
    /// Why the bundle couldn't be parsed, when it couldn't.
    public var problem: String?

    public init(
        id: UUID,
        hostPattern: String,
        label: String,
        isEnabled: Bool,
        subject: String? = nil,
        notAfter: Date? = nil,
        problem: String? = nil
    ) {
        self.id = id
        self.hostPattern = hostPattern
        self.label = label
        self.isEnabled = isEnabled
        self.subject = subject
        self.notAfter = notAfter
        self.problem = problem
    }

    /// Expired as of `now` — cheap to ask, and the first thing to check when an
    /// mTLS host started failing without anything changing on Loom's side.
    public func isExpired(asOf now: Date = Date()) -> Bool {
        guard let notAfter else { return false }
        return notAfter < now
    }
}

/// Client identities for mutual TLS: add/replace, list (without secrets), remove.
///
/// A write here changes which credential Loom presents to a third party, so it is
/// an audited write action like a rule change, not configuration.
public protocol ClientCertificateControlling: Sendable {
    /// Every configured identity, secrets stripped (see `ClientCertificateSummary`).
    func clientCertificates() async -> [ClientCertificateSummary]
    /// Add, or replace the one with the same id. Throws
    /// `ProxyControlError.invalidClientCertificate` when the bundle can't be read
    /// with the given passphrase — validated on the way in, so the failure lands on
    /// the operator who can fix it instead of on a request hours later.
    func setClientCertificate(_ certificate: ClientCertificate) async throws
    /// Remove an identity. Throws `clientCertificateNotFound` when there is no such id.
    func deleteClientCertificate(id: UUID) async throws
}
