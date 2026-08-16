import Foundation
import Testing
@testable import MCPServer

/// Nothing checked that `MCPToolExecutor.redactedArgumentNames` still covers what a
/// tool can be handed.
///
/// ## The stakes, and the direction it fails in
///
/// Every write tool's arguments are recorded in `audit.sqlite` — durable, on disk,
/// and the supervision surface the human reads. Two argument names are redacted
/// there because they carry key material: a PKCS#12 bundle (a private key) and its
/// passphrase. The list is hand-written and matched by string.
///
/// A tool added later with a `client_secret`, an `api_key` or a second `password`
/// argument gets none of that, and nothing anywhere says so. Unlike the audit
/// **opt-out** list — where forgetting an entry costs a redundant read — forgetting
/// one here writes a credential to disk. It is the same shape as every other
/// unguarded mirror in this codebase and the only one whose failure is a leak.
///
/// ## What is checked, and what a census can and cannot decide
///
/// "Is this argument a secret" needs judgement and cannot be derived. What *can* be
/// derived is the weaker, useful form: every advertised property whose **name reads
/// like a credential** must be either redacted or listed below with why it is safe.
/// That converts "remember to redact the next one" into "the next one fails a test",
/// which is the whole move.
///
/// The word list is deliberately broad and the accounted-for list is deliberately
/// specific: a false positive costs one line and a reason, a false negative costs a
/// private key.
@Suite struct AuditRedactionCensusTests {
    /// Substrings that make an argument name worth a second look. Matched
    /// case-insensitively against the whole property name.
    private static let credentialWords = [
        "passphrase", "password", "secret", "token", "credential",
        "apikey", "api_key", "pkcs12", "private", "bearer", "auth",
    ]

    /// Advertised properties that trip the word list and are **not** redacted, each
    /// with the reason that is correct. An entry here is a claim that the value is
    /// not key material — not that redacting it would be inconvenient.
    ///
    /// Empty today: the only two properties the word list catches are the two that
    /// are redacted. It was written with a speculative entry in it, and the stale
    /// check below is what caught that the entry explained a property no tool
    /// advertises — the same dead-note defect the `set_rule` census turned up on its
    /// own first run. A reason nobody can act on is worse than no reason, because it
    /// reads as a decision someone made.
    private static let accountedFor: [String: String] = [:]

    /// Every property name any tool advertises, at any depth.
    private func advertisedPropertyNames() throws -> Set<String> {
        let executor = MCPToolExecutor(engine: StubEngine(), appVersion: "9.9", protocolVersion: "x")
        var names: Set<String> = []
        for definition in executor.toolDefinitions {
            guard let schema = definition["inputSchema"] as? [String: Any] else { continue }
            names.formUnion(propertyNames(in: schema))
        }
        return names
    }

    private func propertyNames(in schema: [String: Any]) -> Set<String> {
        var names: Set<String> = []
        if let properties = schema["properties"] as? [String: Any] {
            for (name, nested) in properties {
                names.insert(name)
                if let nested = nested as? [String: Any] {
                    names.formUnion(propertyNames(in: nested))
                }
            }
        }
        if let items = schema["items"] as? [String: Any] {
            names.formUnion(propertyNames(in: items))
        }
        return names
    }

    @Test func everyCredentialShapedArgumentIsRedactedOrAccountedFor() throws {
        let advertised = try advertisedPropertyNames()
        #expect(advertised.count > 40, "the schema walk stopped finding properties — it is no longer reading the registry")

        for name in advertised.sorted() {
            let lowered = name.lowercased()
            guard Self.credentialWords.contains(where: lowered.contains) else { continue }
            if MCPToolExecutor.redactedArgumentNames.contains(name) { continue }
            if let reason = Self.accountedFor[name] {
                #expect(reason.count > 30, "\(name): needs a real reason, not \"\(reason)\"")
                continue
            }
            Issue.record("""
            `\(name)` is advertised by a tool, reads like a credential, and is not in \
            `MCPToolExecutor.redactedArgumentNames`. Its value is written verbatim to \
            `audit.sqlite`, which is durable and on disk. Redact it, or record it in \
            this suite's `accountedFor` with why it is not key material.
            """)
        }

        // A reason explaining a property no tool advertises reads as a decision
        // someone made about a real argument. It isn't one.
        let stale = Set(Self.accountedFor.keys).subtracting(advertised)
        #expect(
            stale.isEmpty,
            "`accountedFor` explains \(stale.sorted()), which no tool advertises."
        )
    }

    /// The other direction: a redaction entry naming nothing is a redaction that
    /// stopped applying. Unlike a stale opt-out, this one is silent *and* unsafe —
    /// the tool it was written for still takes the argument under some other name.
    @Test func everyRedactionNamesAnAdvertisedArgument() throws {
        let advertised = try advertisedPropertyNames()
        for name in MCPToolExecutor.redactedArgumentNames.sorted() {
            #expect(
                advertised.contains(name),
                """
                `redactedArgumentNames` redacts "\(name)", which no tool advertises. \
                Either it was renamed — in which case the new name is being audited in \
                the clear — or the tool is gone and the entry should be.
                """
            )
        }
    }

    // MARK: - Depth

    /// Redaction used to be a flat pass over the top-level keys, which was correct
    /// only for as long as every secret stayed a top-level property. This pins the
    /// property rather than the current shape: a secret is redacted wherever it sits.
    @Test func aNestedSecretIsRedactedToo() {
        let rendered = MCPToolExecutor.auditArguments([
            "identity": .object([
                "host_pattern": .string("*.corp.example"),
                "passphrase": .string("hunter2"),
            ]),
            "batch": .array([.object(["pkcs12_base64": .string("MIIKfQIBAzCC")])]),
        ])

        #expect(!rendered.contains("hunter2"))
        #expect(!rendered.contains("MIIKfQIBAzCC"))
        #expect(rendered.contains("<redacted>"))
        // The names survive, which is the half supervision needs: "an identity was
        // installed for this host" stays readable.
        #expect(rendered.contains("host_pattern"))
        #expect(rendered.contains("*.corp.example"))
    }

    @Test func anArgumentSetWithNoSecretsIsUnchanged() {
        let rendered = MCPToolExecutor.auditArguments([
            "host_pattern": .string("*.corp.example"),
            "enabled": .bool(true),
        ])
        #expect(rendered.contains("*.corp.example"))
        #expect(!rendered.contains("<redacted>"))
    }
}
