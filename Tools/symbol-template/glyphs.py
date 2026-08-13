#!/usr/bin/env python3
"""Static glyph artwork for Loom's custom SF Symbols.

Unlike `mark.py`, nothing here is generated: these are fixed outlines that look
the same at every weight. That is a deliberate difference and not a shortcut —
`loom.mark` exists in three stroke weights because it *is* a stroked mark and
the menu bar renders it against the system's weight; a solid product glyph has
no stroke to vary, and inventing one per weight would be drawing three different
logos.

It also sidesteps the failure `check.py` exists for by construction: CoreUI
rejects a symbol whose weight variants have no point correspondence, and three
copies of one path are trivially corresponded. `check.py` still covers these,
because "by construction" is exactly the kind of reasoning that has been wrong
here before.

## Third-party artwork

`ANDROID` is from the Jam icon set (https://github.com/michaelampr/jam) by
michaelampr, MIT licensed. Vendoring a *shape* under a permissive licence is
fine and is not what AGENTS.md § Legal boundary is about (transcribing someone
else's source, especially copyleft) — but the attribution is a condition of the
licence, so it stays here, next to the bytes it covers.

The path is the upstream `d` attribute verbatim, in its own `viewBox`
coordinates; `build.py` normalizes and flattens it. Keeping it unmodified is
what makes re-checking it against upstream possible.
"""

# viewBox="-3 -2 24 24" — normalized by the builder, so these numbers stay as
# published rather than being pre-baked into Loom's design box.
ANDROID = (
    "M1.247 6.51h-.051c-.656 0-1.19.537-1.19 1.19v5.183c0 .656.534 1.19 1.19 1.19h.052c.655 0 "
    "1.19-.535 1.19-1.19V7.7c-.001-.654-.536-1.19-1.191-1.19z"
    "M3.007 14.883c0 .602.492 1.092 1.094 1.092h1.17v2.8c0 .657.535 1.191 1.19 1.191h.05c.657 0 "
    "1.192-.535 1.192-1.192v-2.799h1.634v2.8c0 .657.538 1.191 1.192 1.191h.05c.657 0 "
    "1.191-.535 1.191-1.192v-2.799h1.17c.601 0 1.093-.49 1.093-1.092V6.701H3.007v8.182z"
    "M11.266 1.738l.929-1.433a.197.197 0 1 0-.33-.215l-.963 1.483a6.276 6.276 0 0 0-2.38-.462c-.854 "
    "0-1.658.166-2.382.462L5.179.09a.197.197 0 0 0-.275-.058.197.197 0 0 0-.058.273l.93 "
    "1.433C4.1 2.56 2.97 4.107 2.97 5.882c0 .11.006.217.016.323h11.07c.008-.106.014-.214.014-.323 "
    "0-1.775-1.13-3.322-2.805-4.144z"
    "M5.955 4.305a.532.532 0 1 1-.002-1.064.532.532 0 0 1 .002 1.064z"
    "M11.087 4.305a.532.532 0 1 1-.003-1.064.532.532 0 0 1 .003 1.064z"
    "M15.845 6.51h-.05c-.655 0-1.191.537-1.191 1.19v5.183c0 .656.537 1.19 1.191 1.19h.05c.657 0 "
    "1.191-.535 1.191-1.19V7.7c0-.654-.535-1.19-1.191-1.19z"
)

# symbol name -> (path data, how much of the design box's height to fill)
#
# The cap fraction is a per-glyph optical call, not a constant, and it is allowed
# to exceed 1: the design box is the *cap* height, and Apple's own device glyphs
# (`iphone`, `desktopcomputer`) overshoot it — a figure held to the capline sits
# visibly small beside them in the same row. The Android mark is narrow enough to
# take it; `fit` still clamps to the box's width, so the practical ceiling here is
# ~1.23 and past that the number stops doing anything.
STATIC = {
    "loom.device.android": (ANDROID, 1.2),
}
