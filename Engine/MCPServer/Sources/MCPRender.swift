import Foundation
import LoomSharedModels

/// Turning a typed render value into the `[String: Any]` the tool handlers pass
/// to `prettyJSON`.
///
/// ## Why this exists
///
/// Every model an agent reads used to have **two** hand-written representations:
/// the model itself (`Flow`, `ProxyStatus`, `PendingBreakpoint`, …, all `Codable`
/// and therefore compiler-checked) and a hand-built `[String: Any]` render. Only
/// the first grows when a field is added. Adding a field to `Flow` compiled
/// everywhere and the agent silently never saw it — the same failure
/// `RuleCodecParityTests` was written for after it had already happened once to
/// rules.
///
/// So the renders are now `Encodable` DTOs (`MCPRenderModels.swift`) and this is
/// the one place they become JSON. What that buys, concretely:
///
/// - **The field list is a type.** A render field is a stored property with a
///   type, not a string key next to a value of whatever shape the call site had.
/// - **A census can compare it to the model.** `RenderParityTests` encodes both
///   and diffs the key sets, so a model field with no render counterpart fails
///   rather than disappearing.
/// - **Optionals are omitted, once.** Synthesized `encode(to:)` uses
///   `encodeIfPresent` for every optional, which is exactly the
///   `if let x { out["x"] = x }` the hand-built dictionaries repeated per field.
///
/// ## Output is unchanged, deliberately
///
/// This was a refactor of the *renderer*, not of the agent-facing surface: the
/// JSON is byte-identical to what the dictionaries produced. Key names, the
/// omit-when-nil rule, the shaped fields (`captureTruncated`, the body window,
/// the WebSocket slice) all survive as DTO fields with the same names. Dates use
/// `.iso8601`, which is `ISO8601DateFormatter` with `withInternetDateTime` — the
/// same shared formatter the dictionaries used. Key *order* never mattered:
/// `prettyJSON` sorts.
enum MCPRender {
    /// One encoder, configured once. `ISO8601DateFormatter` is expensive to build
    /// and `JSONEncoder` more so; both are immutable after configuration here.
    ///
    /// `nonisolated(unsafe)`: `JSONEncoder` is safe to use concurrently as long as
    /// nothing mutates its configuration, which nothing does — it is configured in
    /// this initializer and only ever asked to `encode`. The class simply isn't
    /// marked `Sendable`. Do not set a strategy anywhere else.
    nonisolated(unsafe) private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// A render DTO as the JSON object the tool handlers embed and `prettyJSON`
    /// serializes.
    ///
    /// The fallback is `[:]` rather than a trap: a render is what an agent reads to
    /// find out what went wrong, and killing the tool call because one value didn't
    /// encode would take the diagnosis with it. It cannot happen for a DTO built
    /// from Foundation scalars — an `assertionFailure` catches it in a debug build,
    /// which is where a new DTO is written.
    static func dict(_ value: some Encodable) -> [String: Any] {
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            assertionFailure("render value did not encode to a JSON object: \(type(of: value))")
            return [:]
        }
        return dictionary
    }

    /// The array form, for a list render (`get_recent_flows`, `list_pending`, …).
    static func array(_ values: [some Encodable]) -> [[String: Any]] {
        values.map(dict)
    }
}

// MARK: - Shared render primitives

/// A header as an agent reads it: an ordered `{name, value}` pair, never a
/// dictionary. Order and duplicates are preserved as seen on the wire — the whole
/// reason `HeaderPair` is a list in the model — so this must stay an array element
/// type rather than becoming a map. (`headerDict` exists for the two places that
/// genuinely want lookup, and loses repeats by design.)
struct RenderedHeader: Encodable {
    var name: String
    var value: String

    init(_ pair: HeaderPair) {
        name = pair.name
        value = pair.value
    }

    static func list(_ pairs: [HeaderPair]) -> [RenderedHeader] { pairs.map(RenderedHeader.init) }
}

/// A captured body, rendered.
///
/// Three shapes, and the distinctions are load-bearing: an agent must be able to
/// tell "no body" from "2 MB of PNG" from "the first 16 KB of a large JSON", and a
/// silent `""` collapses all three. Encoded as a bare string in the common case
/// (whole body, decodes as text) so the ordinary render stays readable.
enum RenderedBody: Encodable {
    /// The whole body as text — including `""` for no body at all.
    case text(String)
    /// Bytes that aren't text. The count is the *whole* body, not the window.
    case binary(bytes: Int)
    /// A window into a larger body, with where to page from next.
    case window(preview: String, bytes: Int, offset: Int, nextOffset: Int?)

    private enum BinaryKeys: String, CodingKey {
        case binary, bytes
    }

    private enum WindowKeys: String, CodingKey {
        case truncated, preview, bytes, offset, nextOffset
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .text(text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        case let .binary(bytes):
            var container = encoder.container(keyedBy: BinaryKeys.self)
            try container.encode(true, forKey: .binary)
            try container.encode(bytes, forKey: .bytes)
        case let .window(preview, bytes, offset, nextOffset):
            var container = encoder.container(keyedBy: WindowKeys.self)
            try container.encode(true, forKey: .truncated)
            try container.encode(preview, forKey: .preview)
            try container.encode(bytes, forKey: .bytes)
            try container.encode(offset, forKey: .offset)
            try container.encodeIfPresent(nextOffset, forKey: .nextOffset)
        }
    }
}
