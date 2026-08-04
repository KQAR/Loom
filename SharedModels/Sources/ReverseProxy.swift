import Foundation

/// A local port that stands in for one upstream origin: Loom accepts plain HTTP on
/// it, captures the exchange, and forwards it to `upstream`.
///
/// This is the escape hatch for clients that cannot be pointed at a proxy. Loom's
/// HTTP and SOCKS ports both need the *client's* cooperation — an absolute request
/// line, or a SOCKS handshake — and a large class of real clients never cooperates:
/// Node's `fetch`/undici ignores `HTTP_PROXY` outright, so a dev server forwarding
/// `/api` to a real backend is invisible no matter how the environment is set. A
/// reverse endpoint inverts the relationship: the client thinks it is talking to an
/// ordinary web server, which every HTTP client knows how to do.
///
/// Two consequences worth stating, because they are the reason this is worth
/// building rather than telling people to configure a proxy agent:
///
/// - **The inbound hop is plain HTTP even when `upstream` is `https://`.** Loom
///   terminates nothing and presents no certificate, so the client needs no CA
///   trust — no `NODE_EXTRA_CA_CERTS`, no keychain step. Loom does the TLS to the
///   upstream itself. (An HTTPS *inbound* endpoint is deliberately not offered:
///   it would reintroduce the CA-trust step this exists to remove.)
/// - **The captured flow's URL is the upstream one**, not `127.0.0.1:port`, so
///   rules, breakpoints and diffs match on the URL the developer thinks in terms
///   of. The local port is transport, not identity.
public struct ReverseProxyEndpoint: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// Port to listen on. `0` asks the OS for a free one — fine for an ad-hoc
    /// session, but a dev server's config names a fixed port, so a real setup
    /// usually pins it.
    public var requestedPort: Int
    /// Origin (and optional base path) requests are forwarded to, e.g.
    /// `https://api.example.com` or `https://api.example.com/v2`. Validated on
    /// creation by `normalizedUpstream(_:)`.
    public var upstream: String
    /// Optional note — which project or scenario this endpoint belongs to.
    public var label: String?
    /// Keep the client's `Host` header (`127.0.0.1:port`) instead of rewriting it to
    /// the upstream host. Off by default because a real server almost always
    /// vhost-routes on `Host`, and sending it `127.0.0.1` yields a 404 that looks
    /// like Loom broke the request. On for the rare upstream that keys off it.
    public var keepHostHeader: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(), requestedPort: Int = 0, upstream: String,
        label: String? = nil, keepHostHeader: Bool = false, createdAt: Date = Date()
    ) {
        self.id = id
        self.requestedPort = requestedPort
        self.upstream = upstream
        self.label = label
        self.keepHostHeader = keepHostHeader
        self.createdAt = createdAt
    }

    /// The upstream as a URL, or nil if the stored string isn't usable — which a
    /// validated endpoint's never is, but a hand-edited config file's can be.
    public var upstreamURL: URL? { URL(string: upstream) }

    /// Validate and canonicalize an upstream string, or throw explaining what is
    /// wrong with it.
    ///
    /// Validation happens **when the endpoint is created**, not when the first
    /// request arrives, for the same reason a client certificate's passphrase is
    /// checked at install time: the alternative is a listener that binds happily and
    /// then fails every request, with the mistake surfacing hours later as "Loom
    /// broke my dev server".
    public static func normalizedUpstream(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProxyControlError.invalidReverseProxy("upstream is empty; expected an origin like https://api.example.com")
        }
        guard var components = URLComponents(string: trimmed) else {
            throw ProxyControlError.invalidReverseProxy("upstream \"\(trimmed)\" is not a URL")
        }
        // A bare host ("api.example.com") parses as a *path* with no scheme, which
        // would otherwise be accepted and then forward to nowhere.
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ProxyControlError.invalidReverseProxy(
                "upstream \"\(trimmed)\" needs an http:// or https:// scheme (a bare host is not enough)")
        }
        guard let host = components.host, !host.isEmpty else {
            throw ProxyControlError.invalidReverseProxy("upstream \"\(trimmed)\" has no host")
        }
        // A query or fragment on an *origin* is meaningless — every forwarded request
        // brings its own — and silently dropping it would misreport what Loom does.
        guard components.query == nil, components.fragment == nil else {
            throw ProxyControlError.invalidReverseProxy(
                "upstream \"\(trimmed)\" must not carry a query or fragment; each forwarded request supplies its own")
        }
        components.scheme = scheme
        // A trailing slash would double up when joined with the request's own path.
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath = String(components.percentEncodedPath.dropLast())
        }
        guard let normalized = components.string else {
            throw ProxyControlError.invalidReverseProxy("upstream \"\(trimmed)\" could not be normalized")
        }
        return normalized
    }

    /// The absolute URL a request arriving on this endpoint is forwarded to:
    /// upstream origin (+ base path) followed by the request's own origin-form
    /// target.
    ///
    /// Kept here, next to the model, because three callers need the same answer —
    /// the listener that forwards, the tool that reports what an endpoint does, and
    /// the tests — and a second implementation would be a second definition of where
    /// traffic goes.
    public func forwardURL(requestTarget: String) -> URL? {
        guard let upstreamURL, var components = URLComponents(url: upstreamURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let base = components.percentEncodedPath
        // Split once from the left: everything after the first `?` is query, even if
        // it contains further `?` characters (legal in a query).
        let target = requestTarget.isEmpty ? "/" : requestTarget
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(split[0])
        components.percentEncodedPath = base + (path.hasPrefix("/") ? path : "/" + path)
        components.percentEncodedQuery = split.count > 1 ? String(split[1]) : nil
        return components.url
    }
}

/// An endpoint plus whether it is actually listening.
///
/// The two are separate because a configured endpoint can fail to bind — the port
/// is taken by the very dev server it was created for, most likely — and that has
/// to be *reportable* rather than fixed up silently. An endpoint that exists in the
/// config but isn't listening is the "why is nothing captured" case for this
/// feature, so `error` carries the reason the bind failed.
public struct ReverseProxyStatus: Equatable, Codable, Sendable, Identifiable {
    public var endpoint: ReverseProxyEndpoint
    /// Port actually bound, or nil when this endpoint isn't listening.
    public var boundPort: Int?
    /// Why it isn't listening. Nil while it is.
    public var error: String?

    public var id: UUID { endpoint.id }
    public var isListening: Bool { boundPort != nil }

    public init(endpoint: ReverseProxyEndpoint, boundPort: Int? = nil, error: String? = nil) {
        self.endpoint = endpoint
        self.boundPort = boundPort
        self.error = error
    }

    /// What a client should be pointed at, e.g. `http://127.0.0.1:9200` — the string
    /// that goes into a dev server's proxy target. Nil while not listening, which is
    /// the honest answer: there is nothing to point at.
    public var localURL: String? {
        boundPort.map { "http://127.0.0.1:\($0)" }
    }
}

/// Create, list and remove reverse-proxy endpoints.
///
/// Defaults are provided so an embedding host that drives `LoomProxyCore` as a
/// library keeps compiling, and so that "this build has no reverse endpoints"
/// reports as an empty list plus a throwing create — never as a listener that
/// silently didn't happen.
public protocol ReverseProxyControlling: Sendable {
    /// Configured endpoints and whether each is listening.
    func reverseProxies() async -> [ReverseProxyStatus]
    /// Validate, bind and persist a new endpoint. Throws
    /// `ProxyControlError.invalidReverseProxy` when the upstream is unusable or the
    /// port can't be bound — a create that couldn't listen must not report success.
    func createReverseProxy(_ endpoint: ReverseProxyEndpoint) async throws -> ReverseProxyStatus
    /// Stop listening and forget the endpoint. Throws
    /// `ProxyControlError.reverseProxyNotFound` when there is no such endpoint.
    func deleteReverseProxy(id: UUID) async throws
}

public extension ReverseProxyControlling {
    func reverseProxies() async -> [ReverseProxyStatus] { [] }

    func createReverseProxy(_ endpoint: ReverseProxyEndpoint) async throws -> ReverseProxyStatus {
        throw ProxyControlError.invalidReverseProxy("this build does not host reverse-proxy endpoints")
    }

    func deleteReverseProxy(id: UUID) async throws {
        throw ProxyControlError.reverseProxyNotFound(id)
    }
}
