import Foundation

/// Percent-decoding for captured wire text.
///
/// Percent-decode only, and **`+` is left alone**. Turning `+` into a space is
/// the `application/x-www-form-urlencoded` convention — a server-side reading,
/// not a property of the bytes (RFC 3986 lists `+` as an ordinary sub-delimiter).
/// Header values and query strings both carry base64 where every `+` is literal;
/// rewriting those would show something that was never sent.
///
/// Returns nil when the string is not percent-encoded, or will not decode
/// (malformed `%`). Callers that must still display the bytes use `?? raw`.
enum PercentDecoding {
    static func decoded(_ raw: String) -> String? {
        guard let decoded = raw.removingPercentEncoding, decoded != raw else { return nil }
        return decoded
    }
}
