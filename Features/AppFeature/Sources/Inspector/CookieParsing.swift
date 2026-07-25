import LoomSharedModels

enum CookieParsing {
    /// Request cookies come from `Cookie: a=1; b=2` header(s).
    static func requestCookies(_ headers: [HeaderPair]) -> [CookieItem] {
        headers
            .filter { $0.name.lowercased() == "cookie" }
            .flatMap { $0.value.components(separatedBy: ";") }
            .compactMap { pair in
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                guard let eq = trimmed.firstIndex(of: "="), eq != trimmed.startIndex else { return nil }
                return CookieItem(
                    name: String(trimmed[..<eq]),
                    value: String(trimmed[trimmed.index(after: eq)...])
                )
            }
    }

    /// Response cookies come from `Set-Cookie` header(s); the first `k=v` is the
    /// cookie, the rest are attributes.
    static func responseCookies(_ headers: [HeaderPair]) -> [CookieItem] {
        headers
            .filter { $0.name.lowercased() == "set-cookie" }
            .compactMap { header in
                let parts = header.value.components(separatedBy: ";")
                guard let first = parts.first?.trimmingCharacters(in: .whitespaces),
                      let eq = first.firstIndex(of: "="), eq != first.startIndex else { return nil }
                let attrs = parts.dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                return CookieItem(
                    name: String(first[..<eq]),
                    value: String(first[first.index(after: eq)...]),
                    attributes: attrs
                )
            }
    }
}
