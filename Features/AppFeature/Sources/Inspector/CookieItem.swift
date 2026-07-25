import Foundation

struct CookieItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let value: String
    /// Set-Cookie attributes (Path, HttpOnly, …), joined for display; empty for request cookies.
    var attributes: String = ""
}
