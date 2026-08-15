#!/usr/bin/env python3
"""Report where a budgeted doc's words actually are, and what reads as history.

`verify-doc-budgets.py` says a file is too long. This says *where* — because the
two answers to "too long" are relocate and condense, and only the first one
scales. Report-only by design: it never exits non-zero and is not wired into CI.

Two reports:

**Section distribution.** Words per `##`/`###` section, so a relocation decision
is made against measurement rather than impression. When this was first run on
AGENTS.md, Known Issues was 32 % of the file and Core Concepts 25 % — which is
the shape that says *move a section's detail to its owning tier*, not *tighten
sentences everywhere*.

**Change-narration candidates.** Lines matching the patterns that mark prose
written from the authoring session's vantage rather than the repository's: "used
to", "no longer", "the old X", "before 0.0.N". These are candidates, never
findings, and that distinction is the whole reason this is not a gate. Loom's
prose deliberately pins regressions with counterfactuals, and the useful form of
one is present-tense — "without X, Y happens" — while the same fact told as
history — "X used to do Y, which was wrong" — costs more words and dates. Both
match the same pattern. A human decides which is which; deleting on the pattern
alone drops true facts.

    scripts/audit-doc-shape.py                 # every budgeted doc
    scripts/audit-doc-shape.py AGENTS.md       # one file
    scripts/audit-doc-shape.py --sections-only
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts" / "doc-budgets.json"

HEADING = re.compile(r"^(#{1,3}) (.+?)\s*#*$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")

NARRATION = [
    ("used to", re.compile(r"\bused to\b", re.I)),
    ("no longer", re.compile(r"\bno longer\b", re.I)),
    ("the old …", re.compile(r"\bthe old \w+", re.I)),
    ("before 0.0.N", re.compile(r"\bbefore 0\.0\.\d+", re.I)),
    ("until/as of 0.0.N", re.compile(r"\b(?:until|as of) 0\.0\.\d+", re.I)),
    ("was wrong / got wrong", re.compile(r"\b(?:was|got|turned out to be) wrong\b", re.I)),
    ("was a bug first", re.compile(r"\bbugs? first\b", re.I)),
]


def sections(path: Path) -> list[tuple[str, int]]:
    """(heading, words) for each `##`/`###` section, code fences included."""
    out: list[tuple[str, int]] = []
    name, body, in_fence, marker = "(preamble)", [], False, ""

    for line in path.read_text(encoding="utf-8").splitlines():
        opener = FENCE.match(line)
        if opener:
            char = opener.group(1)[0]
            if not in_fence:
                in_fence, marker = True, char
            elif char == marker:
                in_fence = False
            body.append(line)
            continue

        heading = None if in_fence else HEADING.match(line)
        if heading and len(heading.group(1)) <= 3:
            out.append((name, len(" ".join(body).split())))
            name, body = heading.group(2), []
            continue
        body.append(line)

    out.append((name, len(" ".join(body).split())))
    return [entry for entry in out if entry[1] > 0]


def report(path: Path, sections_only: bool) -> None:
    rel = path.relative_to(ROOT)
    total = len(path.read_text(encoding="utf-8").split())
    print(f"\n=== {rel} — {total} words")

    for name, words in sorted(sections(path), key=lambda s: -s[1]):
        share = 100 * words / total if total else 0
        bar = "#" * round(share / 2)
        print(f"  {words:>6}  {share:>5.1f}%  {bar:<25} {name[:60]}")

    if sections_only:
        return

    hits: list[tuple[int, str, str]] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for label, pattern in NARRATION:
            for match in pattern.finditer(line):
                start = max(0, match.start() - 55)
                hits.append((number, label, line[start:match.end() + 75].strip()))

    if not hits:
        print("  no change-narration candidates")
        return

    print(f"\n  change-narration candidates ({len(hits)}) — candidates, not findings:")
    for number, label, excerpt in hits:
        print(f"    {rel}:{number}  [{label}]  …{excerpt}…")


def main(argv: list[str]) -> int:
    sections_only = "--sections-only" in argv
    named = [arg for arg in argv if not arg.startswith("--")]

    if named:
        paths = [Path(arg).resolve() for arg in named]
    else:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        paths = [ROOT / key for key in manifest if not key.startswith("_")]

    for path in paths:
        if path.is_file():
            report(path, sections_only)
        else:
            print(f"skipped (no such file): {path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
