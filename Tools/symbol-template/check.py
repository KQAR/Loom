#!/usr/bin/env python3
"""Acceptance test for Loom's custom SF Symbols.

Why this exists: a custom symbol can compile cleanly through `actool`, land in
`Assets.car` with every rendition present, build into the app without a single
warning — and still resolve to **nil** at runtime. CoreUI rejects the symbol
during decode, and nothing upstream says a word; the menu-bar icon just silently
disappears. `Image("loom.mark")` has no compile-time existence check either.

Empirically the trigger is how far the three variants diverge: an Ultralight /
Black stroke spread that is too wide gets rejected while a narrower one is
accepted, with the same geometry, names and margins. We have no documented rule
for the threshold, so the only trustworthy answer is to compile the catalog and
actually ask for the image back.

    python3 Tools/symbol-template/check.py     # exit 0 = every symbol resolves

Run after any edit to mark.py / build.py, and before trusting a build.
"""
import pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
ASSETS = ROOT / "App/Resources/Assets.xcassets"
SYMBOLS = ["loom.mark", "loom.mark.intercept"]

PLIST = ('<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC '
         '"-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
         '<plist version="1.0"><dict><key>CFBundleIdentifier</key>'
         '<string>com.loom.symbolcheck</string><key>CFBundlePackageType</key>'
         '<string>APPL</string></dict></plist>')

PROBE = """import AppKit
let bundle = Bundle(path: CommandLine.arguments[1])!
var bad = false
for name in CommandLine.arguments.dropFirst(2) {
    if let image = bundle.image(forResource: name) {
        print("  ok    \\(name)  \\(image.size)  template=\\(image.isTemplate)")
    } else {
        print("  NIL   \\(name)  — compiled but CoreUI refuses to decode it")
        bad = true
    }
}
exit(bad ? 1 : 0)
"""


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        app = tmp / "Probe.app"
        (app / "Contents/Resources").mkdir(parents=True)
        (app / "Contents/Info.plist").write_text(PLIST)

        compiled = subprocess.run(
            ["xcrun", "actool", str(ASSETS), "--compile", str(app / "Contents/Resources"),
             "--platform", "macosx", "--minimum-deployment-target", "14.0",
             "--app-icon", "AppIcon", "--output-partial-info-plist", str(tmp / "p.plist"),
             "--output-format", "human-readable-text"],
            capture_output=True, text=True)
        if "error:" in (compiled.stdout + compiled.stderr):
            print(compiled.stdout, compiled.stderr, sep="\n")
            return 1

        probe = tmp / "probe.swift"
        probe.write_text(PROBE)
        print(f"resolving {len(SYMBOLS)} symbol(s) from a compiled catalog:")
        result = subprocess.run(["swift", str(probe), str(app), *SYMBOLS], text=True)
        if result.returncode != 0:
            print("\nA symbol did not resolve. Widen nothing — narrow the stroke spread in\n"
                  "mark.py WEIGHTS and re-run build.py, then this check.")
        return result.returncode


if __name__ == "__main__":
    sys.exit(main())
