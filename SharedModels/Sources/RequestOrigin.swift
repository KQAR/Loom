import Foundation

/// Who made a request, carried alongside it through forwarding so rules and
/// breakpoints can match on it — the difference between "mock this endpoint" and
/// "mock this endpoint *for my app*, and leave the browser alone".
///
/// It is the in-flight counterpart of the `sourceApp` / `sourceDevice` a captured
/// `Flow` ends up with: same values, known before the request is forwarded rather
/// than after it completes. Either side can be nil — a LAN device has no local pid,
/// and a replay's origin is inherited from the flow it replays.
public struct RequestOrigin: Equatable, Sendable {
    /// Local process that opened the connection (loopback peers only).
    public var app: SourceApp?
    /// Device the request came from: this Mac, or a LAN device by IP.
    public var device: SourceDevice?

    public init(app: SourceApp? = nil, device: SourceDevice? = nil) {
        self.app = app
        self.device = device
    }

    /// Nothing is known about where this request came from.
    public var isUnknown: Bool { app == nil && device == nil }

    /// The origin of a captured flow — used when re-sending it (replay), so a rule
    /// scoped to an app still applies to a replay of that app's request.
    public init(flow: Flow) {
        self.init(app: flow.sourceApp, device: flow.sourceDevice)
    }
}
