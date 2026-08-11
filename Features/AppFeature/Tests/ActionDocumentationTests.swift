import Foundation
import Testing

@testable import AppFeature

/// A doc comment must have a declaration under it.
///
/// This is a lint, and it exists because the failure it catches is invisible in review
/// and actively misleading afterwards. `AppFeature` has been split into child features
/// over several rounds — audit, rules, breakpoints, reverse proxies — and each split
/// moved `case`s out of the parent's `Action` enum without moving their prose. What was
/// left was two blocks of documentation describing actions that are no longer there:
/// one attached to `connectedDeviceCountChanged` ("A write action was recorded", "The
/// human cleared the audit trail from the panel") and three lines about reverse-proxy
/// endpoints sitting against the enum's closing brace.
///
/// Both compiled, and both read as documentation of whatever they were touching. In a
/// codebase where the comments carry the invariants, a comment on the wrong declaration
/// is worse than no comment at all — so it is checked rather than watched for.
///
/// Read from source through `#filePath`, the same way `VersionFieldParityTests` reads
/// the plugin manifests: there is no reflection that can see a comment.
@Suite struct ActionDocumentationTests {
    /// Every reducer whose `Action` this lint covers.
    ///
    /// `AppFeature.swift` alone was not enough the moment the capture surface moved out:
    /// this lint exists because a split leaves prose behind on whatever declaration it
    /// was touching, and the split itself is what carries that risk — so the file the
    /// cases moved *to* has to be read as well. Named rather than globbed, so adding a
    /// feature is a deliberate line here instead of a silent gap.
    private static let sources = ["AppFeature.swift", "CaptureFeature.swift"]

    private func reducerSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // AppFeature
            .appending(path: "Sources/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `///` block in the file is followed by something it can be documenting.
    ///
    /// Deliberately whole-file rather than only the `Action` enum: the same split
    /// produced the same orphan in `State` twice, and the rule is not about actions.
    @Test(arguments: Self.sources) func noDocCommentIsLeftWithoutADeclaration(_ source: String) throws {
        let lines = try reducerSource(source).split(separator: "\n", omittingEmptySubsequences: false)
        var orphans: [(line: Int, text: String)] = []
        var blockStart: Int?

        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("///") {
                if blockStart == nil { blockStart = index }
                continue
            }
            guard let start = blockStart else { continue }
            blockStart = nil
            // A plain `//` note between the doc block and its declaration is ordinary.
            if line.hasPrefix("//") || line.isEmpty { continue }
            if Self.opensADeclaration(line) { continue }
            orphans.append((start + 1, lines[start].trimmingCharacters(in: .whitespaces)))
        }

        #expect(
            orphans.isEmpty,
            """
            Doc comments with no declaration under them, at \(source) \
            \(orphans.map { "line \($0.line): \($0.text)" }.joined(separator: " · ")). \
            A case that moved to a child feature has to take its prose with it — left \
            behind, it reads as documentation of whichever declaration follows it.
            """
        )
    }

    /// Does this line begin a declaration?
    ///
    /// Walks the leading modifiers and attributes rather than prefix-matching the whole
    /// line, because the prefix version has exactly the failure a lint must not have: it
    /// missed `private(set) var isFinished` and reported a correctly-documented property
    /// as an orphan on its first run. A lint that cries wolf gets deleted, and it takes
    /// the real finding with it.
    static func opensADeclaration(_ line: String) -> Bool {
        let declarations: Set<String> = [
            "case", "var", "let", "func", "init", "subscript", "deinit",
            "struct", "enum", "class", "actor", "protocol", "extension", "typealias", "associatedtype",
        ]
        let modifiers: Set<String> = [
            "public", "private", "fileprivate", "internal", "package", "open",
            "static", "final", "mutating", "nonmutating", "lazy", "weak", "unowned",
            "indirect", "override", "required", "convenience", "dynamic", "class",
            "nonisolated", "isolated", "consuming", "borrowing", "async", "throws", "distributed",
        ]
        for rawToken in line.split(separator: " ") {
            // `private(set)`, `nonisolated(unsafe)`, `unowned(unsafe)` — the argument is
            // part of the modifier, not the start of something else.
            let token = String(rawToken.prefix(while: { $0 != "(" }))
            if token.hasPrefix("@") { continue }        // any attribute
            // `class` is both, so declarations win only when nothing follows it as a
            // modifier would — checking declarations first is right for every other case
            // and `class func` is vanishingly rare here.
            if declarations.contains(token), token != "class" || rawToken == "class" { return true }
            if modifiers.contains(token) { continue }
            return false
        }
        // Every token was an attribute or a modifier, so the line is a declaration's
        // first line with the keyword on the next one — `@discardableResult` on its own,
        // which is how `enforceDisplayCap` is written and the second false positive this
        // lint produced before it was allowed to be strict.
        return !line.isEmpty
    }

    /// The lint has to be able to fail, and it has to not fire on the shapes this file
    /// is full of — both halves, because the first version got the second one wrong.
    @Test func theLintRecognisesDeclarationsAndOrphans() {
        for line in [
            "case flowReceived(Flow)",
            "private(set) var isFinished = false",
            "public static let displayCap = FlowLimits.windowRows",
            "@Presents public var phone: PhoneOnboardingFeature.State?",
            "mutating func recordFlows(_ batch: [Flow]) {",
            "nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()",
            "public struct HostRow: Equatable, Sendable {",
            "@Dependency(\\.proxyClient) var proxyClient",
            "@discardableResult",   // the keyword is on the next line
        ] {
            #expect(Self.opensADeclaration(line), "should be a declaration: \(line)")
        }
        for line in ["}", "return true", ".cancellable(id: CancelID.search)", "]"] {
            #expect(!Self.opensADeclaration(line), "should not be a declaration: \(line)")
        }
    }
}
