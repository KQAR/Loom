#!/usr/bin/env python3
"""Check every relative Markdown link — and every #fragment anchor — resolves.

AGENTS.md delegates most of its detail to other files: the three specs, each
module's own CLAUDE.md, and ~15 records under docs/decisions/. A link that has
rotted is worse than no link, because the sentence still promises the reasoning
is one click away. Anchors rot more quietly than paths: renaming a heading
breaks every `file.md#the-old-heading` pointing at it, and nothing else in this
repo would notice.

What it checks, over every tracked *.md file:

  - inline links and images `[text](target)`, plus reference definitions
    `[id]: target` — including a link whose text wraps across a line break,
    which a line-based scan silently misses; links inside fenced code blocks and
    inline code spans are ignored, because they are samples, not references;
  - a relative path target exists on disk;
  - a `#fragment` on a Markdown target names a real anchor there — either a
    heading (GitHub's slug rules, including the `-1` suffix on duplicates) or
    an explicit `<a id="…">` / `<a name="…">`;
  - a bare `#fragment` resolves within the linking file itself.

What it deliberately does not check: external URLs (no network in a gate — a
404 upstream is not this repo's regression to catch on every push), anchors
into non-Markdown targets, and prose cross-references like `§ Known Issues`,
which are not links and cannot be resolved mechanically. Naming a section in
prose is therefore the *unchecked* form; a relative Markdown link is the
checked one, which is the reason to prefer it.

    scripts/verify-md-links.py            # gate; non-zero on any broken link
    scripts/verify-md-links.py path.md …  # check only these files
"""

from __future__ import annotations

import re
import subprocess
import sys
from bisect import bisect_right
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent

# A fenced block opens and closes on ``` or ~~~ (three or more), optionally
# indented up to three spaces. Links inside are samples, not references.
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")

# Inline links and images. The target stops at whitespace (which starts an
# optional title) or the closing paren. `<...>` wraps a target containing
# spaces. Nested parens in a target are not supported and do not occur here.
INLINE_LINK = re.compile(r"!?\[(?:[^\]\\]|\\.)*\]\(\s*(<[^>]*>|[^\s()]*)[^)]*\)")

# A link reference definition: `[id]: target "optional title"`.
REFERENCE_DEF = re.compile(r"^ {0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")

# An inline code span renders literally, so link syntax inside one is a sample
# of a link, not a link. Removing the span whole is what makes that true: a real
# link whose *text* is code (`[`ROADMAP.md`](ROADMAP.md)`) still matches
# afterwards, because only the bracketed text is emptied.
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)", re.DOTALL)

ATX_HEADING = re.compile(r"^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
EXPLICIT_ANCHOR = re.compile(r"<a\s[^>]*\b(?:id|name)\s*=\s*[\"']([^\"']+)[\"']", re.IGNORECASE)

# Targets that are not repository paths.
EXTERNAL = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//)", re.IGNORECASE)

MARKDOWN_SUFFIXES = {".md", ".markdown"}


def strip_inline_markup(text: str) -> str:
    """Heading text as GitHub renders it, for slug purposes.

    Only the constructs that actually appear in headings here: code spans,
    links (kept as their text), emphasis markers, and inline HTML.
    """
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    text = re.sub(r"`+([^`]*)`+", r"\1", text)
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    return text.replace("*", "").replace("_", "").strip()


def slugify(heading: str) -> str:
    """GitHub's heading slug: lowercase, drop punctuation, spaces to hyphens."""
    slug = strip_inline_markup(heading).lower()
    slug = re.sub(r"[^\w\- ]", "", slug, flags=re.UNICODE)
    return slug.replace(" ", "-")


def anchors_of(path: Path) -> set[str]:
    """Every fragment a link may target in one Markdown file."""
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return set()

    anchors: set[str] = set()
    seen: dict[str, int] = {}
    in_fence = False
    fence_marker = ""

    for line in source.splitlines():
        opener = FENCE.match(line)
        if opener:
            marker = opener.group(1)[0]
            if not in_fence:
                in_fence, fence_marker = True, marker
                continue
            if marker == fence_marker:
                in_fence = False
            continue
        if in_fence:
            continue

        anchors.update(match.lower() for match in EXPLICIT_ANCHOR.findall(line))

        heading = ATX_HEADING.match(line)
        if not heading:
            continue
        slug = slugify(heading.group(2))
        if not slug:
            continue
        # GitHub disambiguates repeats with -1, -2, … in document order.
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        anchors.add(slug if count == 0 else f"{slug}-{count}")

    return anchors


def links_of(path: Path) -> list[tuple[int, str]]:
    """Every link target in one file, with its 1-based source line."""
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []

    found: list[tuple[int, str]] = []
    in_fence = False
    fence_marker = ""

    # Scanned as one string rather than line by line, because a link whose text
    # wraps — `[some long\n  label](target)` — is a link GitHub renders and a
    # line-based scan cannot see. It was invisible here until a wrapped link in a
    # skill file quietly stopped being checked. Masking (rather than deleting)
    # fenced blocks and code spans keeps every byte offset, so a match still maps
    # back to the line it started on.
    masked: list[str] = []
    for line in source.splitlines():
        opener = FENCE.match(line)
        if opener:
            marker = opener.group(1)[0]
            if not in_fence:
                in_fence, fence_marker = True, marker
            elif marker == fence_marker:
                in_fence = False
            masked.append(" " * len(line))
            continue
        masked.append(" " * len(line) if in_fence else line)

    text = "\n".join(masked)
    text = CODE_SPAN.sub(lambda m: " " * len(m.group(0)), text)

    # Offsets of each line start, for offset -> 1-based line number.
    starts, offset = [], 0
    for line in masked:
        starts.append(offset)
        offset += len(line) + 1

    def line_of(position: int) -> int:
        return bisect_right(starts, position)

    for match in INLINE_LINK.finditer(text):
        found.append((line_of(match.start()), match.group(1)))
    for match in re.finditer(r"(?m)" + REFERENCE_DEF.pattern, text):
        found.append((line_of(match.start()), match.group(1)))

    cleaned: list[tuple[int, str]] = []
    for number, target in found:
        target = target.strip()
        if target.startswith("<") and target.endswith(">"):
            target = target[1:-1]
        if target:
            cleaned.append((number, target))

    return cleaned


def tracked_markdown() -> list[Path]:
    """Every tracked Markdown file, one entry per real file.

    CLAUDE.md is a symlink to AGENTS.md and git tracks both, so without the
    dedupe every finding in that file would be reported twice under two names.
    """
    listing = subprocess.run(
        ["git", "ls-files", "-z", "*.md", "*.markdown"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout

    files: list[Path] = []
    seen: set[Path] = set()
    for name in listing.split("\0"):
        if not name:
            continue
        resolved = (ROOT / name).resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        files.append(resolved)
    return files


def main(argv: list[str]) -> int:
    files = [Path(arg).resolve() for arg in argv] if argv else tracked_markdown()

    anchor_cache: dict[Path, set[str]] = {}

    def anchors(path: Path) -> set[str]:
        if path not in anchor_cache:
            anchor_cache[path] = anchors_of(path)
        return anchor_cache[path]

    failures: list[str] = []
    checked = 0

    for path in files:
        for line, target in links_of(path):
            if EXTERNAL.match(target):
                continue

            where = f"{path.relative_to(ROOT)}:{line}"
            raw_path, _, fragment = target.partition("#")
            fragment = unquote(fragment).lower()

            if raw_path:
                resolved = (path.parent / unquote(raw_path)).resolve()
                checked += 1
                if not resolved.exists():
                    failures.append(f"{where}: no such file — {target}")
                    continue
            else:
                resolved = path  # a bare #fragment targets the linking file

            if not fragment:
                continue
            if resolved.is_dir() or resolved.suffix.lower() not in MARKDOWN_SUFFIXES:
                continue  # anchors into non-Markdown targets are not ours to resolve

            checked += 1
            if fragment not in anchors(resolved):
                failures.append(
                    f"{where}: no anchor '#{fragment}' in "
                    f"{resolved.relative_to(ROOT)} — heading renamed?"
                )

    if failures:
        print("verify-md-links failed:\n", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        print(
            f"\n{len(failures)} broken reference(s) across {len(files)} Markdown files.",
            file=sys.stderr,
        )
        return 1

    print(f"verify-md-links: {checked} relative references across {len(files)} files resolve.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
