import AppKit
import SwiftUI
import Testing

@testable import AppFeature

/// `LoomTheme.Palette` reads its hues from color sets in AppFeature's own asset
/// catalog. The *symbol* half of that is checked by the compiler — `Color(.loomError)`
/// is generated from the catalog, so a renamed or deleted set fails the build.
///
/// What the compiler cannot check is whether the catalog reached the built product:
/// symbol generation happens from the source catalog, so a `resources:` glob that
/// stops matching (or a target that loses the resource phase) compiles clean and
/// then resolves to nothing at runtime. That is the exact shape of the custom-SF-Symbol
/// failure recorded in AGENTS.md § Known Issues — clean build, missing art, silent —
/// and it costs more to find from a screenshot than from here.
@Suite struct PaletteAssetTests {
    /// Every set the palette names. Kept as strings *only here*: this test is the one
    /// place that wants to ask the bundle a question the symbols answer by fiat.
    private static let sets = [
        "LoomAccent", "LoomSuccess", "LoomRedirect",
        "LoomWaiting", "LoomError", "LoomSyntaxBool",
    ]

    /// The framework bundle, reached through a type that lives in it.
    private var bundle: Bundle { Bundle(for: FaviconLoader.self) }

    @Test func everyPaletteColorSetIsPresentInTheBuiltBundle() {
        for name in Self.sets {
            #expect(NSColor(named: name, bundle: bundle) != nil,
                    "Color set '\(name)' is missing from AppFeature's bundle — check the target's resources glob in Project.swift")
        }
    }

    /// A set that forgot its Dark entry resolves fine and is simply *wrong* in dark
    /// mode, which is invisible until someone switches appearance. Each of these is
    /// authored as a light/dark pair, so equal resolutions mean an entry was lost.
    @Test func everyPaletteColorHasDistinctLightAndDarkEntries() {
        for name in Self.sets {
            guard let color = NSColor(named: name, bundle: bundle) else { continue } // reported above
            let light = color.resolved(for: .aqua)
            let dark = color.resolved(for: .darkAqua)
            #expect(light != dark, "Color set '\(name)' resolves identically in light and dark — its Dark entry is missing")
        }
    }

    /// The reason the palette is a catalog rather than a `dynamicProvider` closure:
    /// Increase Contrast is honored by AppKit's own resolution, from data. A set that
    /// loses its high-contrast entries goes back to being a code-shaped problem, and
    /// nothing would fail — the app just quietly stops answering the accessibility
    /// setting.
    ///
    /// Checked by reading the **source** catalog rather than by resolving colors, and
    /// that is a finding worth keeping: an appearance-based read cannot see these.
    /// `actool` keys the high-contrast *light* entry as `NSAppearanceNameAccessibilitySystem`
    /// (contrast only, any luminosity) — verified with `assetutil --info` on the built
    /// `Assets.car` — so resolving under `.accessibilityHighContrastAqua` matches
    /// nothing and falls back to the base color, which reads exactly like a missing
    /// entry. The dark/light test above is what covers the compiled catalog; this one
    /// covers what was authored.
    @Test func everyPaletteColorSetDeclaresAllFourAppearances() throws {
        for name in Self.sets {
            let url = Self.catalog
                .appendingPathComponent("\(name).colorset")
                .appendingPathComponent("Contents.json")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let colors = json?["colors"] as? [[String: Any]] ?? []

            /// The appearance combination of one entry, as a set of `value` strings —
            /// `[]` for the base entry, `["dark"]`, `["high"]`, `["dark", "high"]`.
            let combinations = colors.map { entry -> Set<String> in
                let appearances = entry["appearances"] as? [[String: String]] ?? []
                return Set(appearances.compactMap { $0["value"] })
            }

            #expect(combinations.contains([]), "'\(name)' has no base (Any) entry")
            #expect(combinations.contains(["dark"]), "'\(name)' has no Dark entry")
            #expect(combinations.contains(["high"]), "'\(name)' has no High Contrast (Any) entry")
            #expect(combinations.contains(["dark", "high"]), "'\(name)' has no High Contrast Dark entry")
        }
    }

    /// Reached through `#filePath` rather than the bundle, the same way
    /// `VersionFieldParityTests` reads the manifests: the question is what is
    /// *authored*, and the built product has already folded these into one binary.
    private static let catalog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // AppFeature/
        .appendingPathComponent("Resources/Assets.xcassets")

    /// CONNECT is the only uncoloured method (a tunnel, not a verb), and the **six
    /// acting verbs** are mutually distinct. `OPTIONS` / `TRACE` / unknown verbs
    /// deliberately share one grey — the palette has seven hues and there are more
    /// verbs than that, so the shortage is spent where it says the least.
    @Test func connectIsTheOnlyUncolouredMethod() {
        #expect(LoomTheme.methodTint("CONNECT") == nil)
        #expect(LoomTheme.methodTint("connect") == nil)
        #expect(LoomTheme.methodColor("CONNECT") == .primary)

        let verbs = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
        let colours = verbs.map { LoomTheme.methodColor($0) }
        for (i, left) in colours.enumerated() {
            #expect(LoomTheme.methodTint(verbs[i]) != nil, "\(verbs[i]) must not share CONNECT's uncoloured ink")
            #expect(left != .primary, "\(verbs[i]) must not resolve to CONNECT's ink")
            #expect(left != LoomTheme.Palette.pending, "\(verbs[i]) is an acting verb, not a metadata one")
            for j in (i + 1) ..< colours.count {
                #expect(left != colours[j], "\(verbs[i]) and \(verbs[j]) share a hue")
            }
        }
    }

    /// The shared grey is one value from the palette, and it is shared *on purpose*
    /// — pinned so a future edit that gives TRACE a hue of its own has to decide
    /// which acting verb loses one.
    @Test func metadataVerbsShareOneGreyFromThePalette() {
        for verb in ["OPTIONS", "TRACE", "PROPFIND", "MKCALENDAR"] {
            #expect(LoomTheme.methodColor(verb) == LoomTheme.Palette.pending, "\(verb)")
            #expect(LoomTheme.methodTint(verb) != nil, "shared grey is still a tint, not CONNECT's ink")
        }
    }

    @Test func methodHuesMatchTheNamedPalette() {
        #expect(LoomTheme.methodColor("GET") == LoomTheme.Palette.success)
        #expect(LoomTheme.methodColor("POST") == LoomTheme.Palette.accent)
        #expect(LoomTheme.methodColor("PUT") == LoomTheme.Palette.redirect)
        #expect(LoomTheme.methodColor("PATCH") == LoomTheme.Palette.waiting)
        #expect(LoomTheme.methodColor("DELETE") == LoomTheme.Palette.error)
        #expect(LoomTheme.methodColor("HEAD") == LoomTheme.Palette.Syntax.bool)
        // Metadata verbs and unknown ones recede to one palette grey, never to
        // CONNECT's ink and never to a colour from outside the palette.
        #expect(LoomTheme.methodColor("OPTIONS") == LoomTheme.Palette.pending)
        #expect(LoomTheme.methodColor("TRACE") == LoomTheme.Palette.pending)
        #expect(LoomTheme.methodColor("PROPFIND") == LoomTheme.Palette.pending)
    }
}

private extension NSColor {
    /// Resolve this dynamic color under a named appearance, as sRGB components, so two
    /// resolutions can be compared. `usingColorSpace` is what forces the catalog's
    /// dynamic color to collapse to a concrete one; without it the comparison is
    /// between two identical *proxies*, which would make every expectation above pass.
    func resolved(for appearanceName: NSAppearance.Name) -> [CGFloat] {
        var out: [CGFloat] = []
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            guard let c = usingColorSpace(.sRGB) else { return }
            out = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
        }
        return out
    }
}
