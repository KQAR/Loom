import Foundation
import LoomSharedModels

/// Non-fatal warnings about a body an operator handed Loom to send.
///
/// Loom validates the *shape* of a `tools/call` (unknown keys → `-32602`,
/// `body_base64` → real base64, `status_code` → a real status), but the bytes of a
/// body are deliberately not validated: mocking a malformed payload is a first-class
/// debugging move, and refusing it would remove a capability. A typo in a
/// hand-written JSON mock is the far more common case though, and it fails in the
/// worst possible way — the rule is created, the tool reports success, and the
/// client under test gets a parse error that reads as *its* bug. That is exactly the
/// class of silence this project treats as a defect (AGENTS.md § "a log line is not
/// enough"): the engine holds the fact, so it must reach the operator.
///
/// So the answer is a warning, not a refusal: the write happens as asked, and the
/// result carries `warnings` naming the field and the parse error. Two conditions
/// trigger it, and both are needed — a body whose declared `Content-Type` says JSON
/// (the promise is broken) **or** a body that plainly looks like JSON, `{`/`[`
/// leading (the promise was never made, but nobody types `{"a":}` on purpose and
/// means it). Neither fires on a body that is not trying to be JSON at all.
extension MCPToolExecutor {
    /// One warning for `body`, or nil when there is nothing to say.
    ///
    /// - Parameters:
    ///   - contentType: the declared type, when the same call declared one. A rewrite
    ///     that sets no `Content-Type` inherits the live exchange's, which isn't known
    ///     here — so those fall back to the looks-like-JSON test alone rather than
    ///     guessing.
    ///   - label: how the operator named the field, dotted as they passed it
    ///     (`actions.mockResponse.body`), so the fix is unambiguous when a rule
    ///     carries more than one body.
    static func malformedJSONWarning(body: String?, contentType: String?, label: String) -> String? {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let declaresJSON = contentType?.lowercased().contains("json") == true
        guard declaresJSON || looksLikeJSON(body) else { return nil }
        // `.fragmentsAllowed` because RFC 8259 makes a bare scalar a legal document:
        // a mock returning `42` or `"ok"` with a JSON content type is valid, and
        // warning about it would be noise the operator learns to ignore.
        guard let failure = jsonParseFailure(body) else { return nil }

        let claim = declaresJSON
            ? "its Content-Type declares JSON"
            : "it starts like a JSON document"
        return """
        \(label) is not valid JSON, and \(claim): \(failure). Loom sends the bytes \
        exactly as given — ignore this if an invalid payload is what you are testing.
        """
    }

    /// Warnings for every body a rule carries. Empty when the rule has none, or
    /// when each one parses.
    static func bodyWarnings(for actions: RuleActions) -> [String] {
        var warnings: [String] = []
        if case let .mock(mock) = actions.route {
            // An explicit `content_type` wins over a Content-Type header, matching how
            // the mock is actually served.
            let declared = mock.contentType ?? contentType(of: mock.headers)
            if let warning = malformedJSONWarning(
                body: mock.bodyText, contentType: declared, label: "actions.mockResponse.body"
            ) {
                warnings.append(warning)
            }
        }
        if let rewrite = actions.rewriteRequest, let warning = malformedJSONWarning(
            body: rewrite.bodyText,
            contentType: contentType(of: rewrite.setHeaders),
            label: "actions.rewriteRequest.body"
        ) {
            warnings.append(warning)
        }
        if let rewrite = actions.rewriteResponse, let warning = malformedJSONWarning(
            body: rewrite.bodyText,
            contentType: contentType(of: rewrite.setHeaders),
            label: "actions.rewriteResponse.body"
        ) {
            warnings.append(warning)
        }
        return warnings
    }

    /// Warnings for a `body` argument sent alongside `set_headers` — the shape
    /// `replay_flow` and `resume` share.
    static func bodyWarnings(fromArguments arguments: [String: Any]) -> [String] {
        var declared: String?
        if let raw = arguments["set_headers"] as? [String: Any] {
            declared = contentType(of: raw.map { HeaderPair(name: $0.key, value: String(describing: $0.value)) })
        }
        return [malformedJSONWarning(
            body: arguments["body"] as? String, contentType: declared, label: "body"
        )].compactMap { $0 }
    }

    /// Merge warnings into a rendered result under one well-known key. Absent when
    /// there are none, so its presence always means something needs reading.
    static func attach(warnings: [String], to payload: inout [String: Any]) {
        guard !warnings.isEmpty else { return }
        payload["warnings"] = warnings
    }

    private static func contentType(of headers: [HeaderPair]) -> String? {
        headers.first { $0.name.lowercased() == "content-type" }?.value
    }

    private static func looksLikeJSON(_ body: String) -> Bool {
        guard let first = body.first(where: { !$0.isWhitespace && !$0.isNewline }) else { return false }
        return first == "{" || first == "["
    }

    /// The parse error for a body that isn't JSON, or nil when it parses.
    private static func jsonParseFailure(_ body: String) -> String? {
        do {
            _ = try JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])
            return nil
        } catch {
            // Cocoa's message ("Invalid value around line 1, column 5.") names the
            // position, which is the part that makes the typo findable. Its trailing
            // period goes, because the caller embeds it mid-sentence.
            let message = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                ?? error.localizedDescription
            return message.hasSuffix(".") ? String(message.dropLast()) : message
        }
    }
}
