import Foundation

/// A parsed JSON value, as a checked `Sendable` type.
///
/// `JSONSerialization` hands back `Any` holding `NSString` / `NSNumber` / `NSNull`
/// / `NSArray` / `NSDictionary`. That `Any` is why every handler signature, the
/// audit rendering and the argument validator were all unprovable to the compiler,
/// and why passing arguments from a `@MainActor` test to a nonisolated `call`
/// needed `sending`. Converting once at the transport boundary makes the rest of
/// the tool surface ordinary typed code.
///
/// **`Any` is allowed exactly at the two Foundation boundaries** — the raw
/// dictionary `JSONSerialization` produces on the way in (`MCPToolExecutor.call`),
/// and the object it consumes on the way out (`json`, used by the audit trail).
/// Anywhere else it is a value the compiler cannot check for no benefit.
///
/// Integers and doubles are kept apart, which JSON itself does not do, for two
/// reasons that both showed up in practice: `int` must be able to reject a
/// fractional value instead of truncating it, and the audit trail records the
/// arguments as JSON, where a `limit` of `20` re-serializing as `20.0` is a
/// gratuitous difference between what the agent sent and what the human reads.
enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    // MARK: - From Foundation

    /// Convert one value out of `JSONSerialization`. Anything unrecognized becomes
    /// `.string(String(describing:))` rather than being dropped: this runs on
    /// attacker-reachable input, and a value silently vanishing is how a rejected
    /// argument reads as an absent one.
    init(json: Any) {
        switch json {
        case let text as String: self = .string(text)
        case let value as Bool where Self.isBoolean(json): self = .bool(value)
        case let number as NSNumber: self = Self.number(number)
        case let array as [Any]: self = .array(array.map(JSONValue.init(json:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(json:)))
        case is NSNull: self = .null
        default: self = .string(String(describing: json))
        }
    }

    static func object(fromJSON object: [String: Any]) -> [String: JSONValue] {
        object.mapValues(JSONValue.init(json:))
    }

    /// `NSNumber` does not distinguish a JSON `true` from a `1`; its Objective-C
    /// type does. Checked before the numeric branch, because `as? Bool` on the
    /// NSNumber `1` succeeds and would turn every 1 into `true`.
    private static func isBoolean(_ json: Any) -> Bool {
        guard let number = json as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func number(_ number: NSNumber) -> JSONValue {
        // A JSON integer arrives as an NSNumber whose Objective-C type is one of the
        // integer encodings; `doubleValue` on it is lossless for everything an Int
        // can hold, so the discriminator is the encoding, not a round-trip test.
        switch String(cString: number.objCType) {
        case "c", "C", "s", "S", "i", "I", "l", "L", "q", "Q":
            return .int(number.intValue)
        default:
            let double = number.doubleValue
            // A whole double is still recorded as a double: `20.0` on the wire was
            // written that way, and `int(_:)` accepts it regardless.
            return .double(double)
        }
    }

    // MARK: - Back to Foundation

    /// The `JSONSerialization`-consumable form, for the audit trail's rendering.
    var json: Any {
        switch self {
        case let .string(text): text
        case let .int(value): value
        case let .double(value): value
        case let .bool(value): value
        case let .array(values): values.map(\.json)
        case let .object(values): values.mapValues(\.json)
        case .null: NSNull()
        }
    }
}

// MARK: - Literals

// So a test (and a call site building arguments by hand) writes
// `["max_seconds": 0.05, "until": "response"]` exactly as it did against
// `[String: Any]`. Only literals convert implicitly; a computed `String` has to say
// `.string(x)`, which is the honest half of the trade.
extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}
