import Foundation
import LoomSharedModels
import Testing
@testable import MCPServer

/// Every write tool whose arguments mirror a model, checked against that model.
///
/// ## The failure this exists to catch
///
/// It is the schema-side twin of `RenderParityTests`, and the hole was open for
/// exactly as long. A model is `Codable`, so its serialization grows when a field
/// is added; a hand-written input schema does not, and nothing anywhere says so.
/// Add `var requireStapling: Bool` to `ClientCertificate` and the whole app still
/// compiles, the console can set it, the render can show it — and the agent, whose
/// only vocabulary is `tools/list`, can never send it. The next person to look
/// concludes Loom doesn't support it over MCP.
///
/// `RuleCodecParityTests` closed this for `set_rule` in 0.0.19 and stayed the only
/// entry for eight releases. `SchemaCensus` is that suite's plumbing, lifted out;
/// this file is the sweep it was always the first case of.
///
/// ## Why a tool is here or isn't
///
/// A tool belongs here when its arguments *mirror a model* — when there is a type
/// in `SharedModels` such that "did every field reach the agent" is a question with
/// an answer. `set_recording`, `delete_rule`, `intercept_host` and the read tools
/// take a scalar or two of their own invention; there is no model to drift from,
/// and inventing one to be censused against would be the second copy this whole
/// approach exists to avoid.
///
/// Extra schema properties are never an error (see `SchemaCensus`): `replay_flow`
/// advertises `count`/`concurrency` and `resume` advertises `abort`, none of which
/// is a field of anything.
@Suite struct InputSchemaCensusTests {
    // MARK: - Fixtures
    //
    // Maximal values, deliberately: `Mirror` cannot report the shape of a `nil`
    // optional, so a fixture that leaves one empty hides every field underneath it.

    /// The shared `match` vocabulary, filled in. Both `set_rule` and `arm_breakpoint`
    /// embed `Self.matchSchema`, so censusing it once through the breakpoint covers
    /// the rule's copy too — which is the point of it being one schema value.
    private var match: RuleMatch {
        RuleMatch(
            urlPattern: "https://api.example.test/*",
            style: .glob,
            methods: ["GET"],
            query: ["v": .equals("2")],
            sourceApp: "com.example.app",
            deviceIP: "192.168.1.9",
            expiredHostPattern: "*.example.test"
        )
    }

    // MARK: - Breakpoints

    @Test func armBreakpoint_advertisesEveryBreakpointField() throws {
        try SchemaCensus.check(
            tool: "arm_breakpoint",
            modelFields: SchemaCensus.fieldNames(
                of: Breakpoint(match: match, comment: "why")
            ),
            aliases: [
                "style": "match_style",
            ],
            omissions: [
                "id": "server-assigned on arm; the id an agent would send is one nothing has issued yet, and disarm_breakpoint reads it back from the reply",
                "createdAt": "server-stamped on arm, like every other creation time on this surface — an agent-supplied one would be a lie",
                "expiredHostPattern": "Decode leftover from a pre-fold host_pattern; not an authoring field — fold the glob into url_pattern instead",
                "preparedGlob": "A cache derived from url_pattern + match_style; nothing for an agent to send, and a sent one could only disagree with the pattern it comes from",
            ]
        )
    }

    @Test func resume_advertisesEveryEditField() throws {
        try SchemaCensus.check(
            tool: "resume",
            modelFields: SchemaCensus.fieldNames(
                of: BreakpointEdit(
                    method: "POST",
                    url: "https://api.example.test/v1",
                    statusCode: 503,
                    setHeaders: [HeaderPair(name: "X-A", value: "1")],
                    removeHeaders: ["Cookie"],
                    body: .replace(Data("x".utf8))
                )
            ),
            aliases: [
                // `BodyOverride`'s three cases reach the wire as two keys: `body`
                // carries the replacement bytes, `clear_body` is the empty one, and
                // `keep` is what sending neither means.
                "replace": "body",
            ]
        )
    }

    // MARK: - Replay

    @Test func replayFlow_advertisesEveryOverrideField() throws {
        try SchemaCensus.check(
            tool: "replay_flow",
            modelFields: SchemaCensus.fieldNames(
                of: ReplayOverrides(
                    method: "POST",
                    url: "https://api.example.test/v1",
                    setHeaders: [HeaderPair(name: "X-A", value: "1")],
                    removeHeaders: ["Cookie"],
                    body: .replace(Data("x".utf8))
                )
            ),
            aliases: ["replace": "body"]
        )
    }

    // MARK: - Reverse proxies

    @Test func createReverseProxy_advertisesEveryEndpointField() throws {
        try SchemaCensus.check(
            tool: "create_reverse_proxy",
            modelFields: SchemaCensus.fieldNames(
                of: ReverseProxyEndpoint(
                    requestedPort: 8081,
                    upstream: "https://api.example.test",
                    label: "staging",
                    keepHostHeader: true
                )
            ),
            aliases: [
                // The endpoint stores what was *asked for*, because a request for 0
                // and a bound 51234 are different facts; the wire has one word for
                // the one an agent supplies.
                "requestedPort": "port",
            ],
            omissions: [
                "id": "server-assigned on create; delete_reverse_proxy reads it back from the reply rather than the agent inventing one",
                "createdAt": "server-stamped: an endpoint is config, and its creation time is not something an agent decides",
            ]
        )
    }

    // MARK: - Client certificates

    @Test func setClientCertificate_advertisesEveryIdentityField() throws {
        try SchemaCensus.check(
            tool: "set_client_certificate",
            modelFields: SchemaCensus.fieldNames(
                of: ClientCertificate(
                    hostPattern: "*.corp.example",
                    pkcs12: Data([0x30]),
                    passphrase: "s3cret",
                    label: "corp",
                    isEnabled: true
                )
            ),
            aliases: [
                "pkcs12": "pkcs12_base64",
                "isEnabled": "enabled",
            ]
            // No omissions: `id` *is* advertised here, because this tool is an
            // upsert — passing one replaces that identity rather than adding a
            // second. That is the difference from create_reverse_proxy above, and
            // it is why the census reads each tool against its own model rather
            // than applying one rule about ids.
        )
    }

    // MARK: - The flow filter

    /// The one case that is not a write tool, and the reason the scope line for this
    /// suite is "arguments mirror a model" rather than "write tool".
    ///
    /// `flowFilterProperties` is shared verbatim by `get_recent_flows`,
    /// `wait_for_flow` and `get_stats`, and it mirrors `FlowQuery` — which is
    /// `Codable` and grows for free while the schema does not. A `FlowQuery` field
    /// no schema advertises is a filter the engine can apply and the agent cannot
    /// ask for; worse than a missing write, because the agent's fallback is to pull
    /// a large list and scan it itself, which the tool descriptions explicitly tell
    /// it not to do.
    ///
    /// Censused through `get_recent_flows` — the three tools embed the same value,
    /// so one covers all of them, which is the point of it being one value.
    @Test func flowFilter_advertisesEveryQueryField() throws {
        try SchemaCensus.check(
            tool: "get_recent_flows",
            modelFields: SchemaCensus.fieldNames(
                of: FlowQuery(
                    host: "api.example.test",
                    methods: ["GET"],
                    recordKind: .exchange,
                    urlContains: "orders",
                    statusMin: 400,
                    statusMax: 599,
                    onlyErrors: true,
                    since: Date(timeIntervalSince1970: 0),
                    deviceIP: "192.168.1.9",
                    sourceApp: "com.example.app",
                    headerContains: "x-env: staging",
                    headerSide: .request,
                    bodyContains: "order-7",
                    bodySide: .request
                )
            ),
            aliases: [
                // Singular on the wire: the argument takes a string *or* an array,
                // and `method: "GET"` is what an agent writes far more often.
                "methods": "method",
                "recordKind": "record_type",
                // `…_in` rather than `…_side`: it reads as a place in the exchange,
                // which is the question ("was this header in the request?").
                "headerSide": "header_in",
                "bodySide": "body_in",
            ]
        )
    }

    // MARK: - SSL scope

    @Test func setSSLScope_advertisesEveryScopeField() throws {
        try SchemaCensus.check(
            tool: "set_ssl_scope",
            modelFields: SchemaCensus.fieldNames(
                of: SSLScope(enabled: true, include: ["*.example.test"], exclude: ["pinned.test"])
            )
        )
    }
}
