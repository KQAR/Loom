#!/usr/bin/env python3
"""Enforce the word ceilings in scripts/doc-budgets.json.

AGENTS.md loads in full at the start of every session, so its size is a cost
paid on every task rather than only when someone opens it. The same is true of
the three specs it delegates to. Nothing measured that cost before this gate,
and the file grew to the point where a quarter of it was postmortem — which is
what motivated docs/decisions/ and this ratchet together.

A ceiling is a ratchet, not a reduction target: it fails on *growth*, so the
only way past it is to relocate content to the tier that owns it, condense it,
or raise the ceiling deliberately and say why in the PR. The per-file targets
and the relocate -> condense -> raise order live in AGENTS.md; this script only
holds the line.

Counting is `wc -w` — whitespace-delimited tokens over the raw file, code
fences and link syntax included. A smarter count (prose only, rendered text)
would be a better measure of what a reader pays and a worse gate: it would
disagree with the one command anyone can run to check a file by hand.

    scripts/verify-doc-budgets.py            # gate; non-zero on any failure
    scripts/verify-doc-budgets.py --list     # report usage, always exit 0
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts" / "doc-budgets.json"


def count_words(text: str) -> int:
    """`wc -w` equivalent: whitespace-delimited tokens."""
    return len(text.split())


def main() -> int:
    list_only = "--list" in sys.argv[1:]

    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"verify-doc-budgets: cannot read {MANIFEST.relative_to(ROOT)}: {error}",
              file=sys.stderr)
        return 1

    failures: list[str] = []
    rows: list[str] = []

    for path, ceiling in manifest.items():
        if path.startswith("_"):
            continue  # manifest commentary, not a budgeted file

        if not isinstance(ceiling, int) or isinstance(ceiling, bool) or ceiling <= 0:
            rows.append(f"BAD        —  / {ceiling!r:<7} {path}")
            failures.append(f"{path}: ceiling must be a positive integer, got {ceiling!r}")
            continue

        target = ROOT / path
        if not target.is_file():
            rows.append(f"MISSING    —  / {ceiling:<7} {path}")
            failures.append(
                f"{path}: budgeted file does not exist. Renamed or deleted? "
                f"Update scripts/doc-budgets.json in the same change."
            )
            continue

        words = count_words(target.read_text(encoding="utf-8"))
        headroom = ceiling - words
        status = "ok " if words <= ceiling else "OVER"
        rows.append(f"{status}  {words:>7} / {ceiling:<7} {headroom:+d}  {path}")
        if words > ceiling:
            failures.append(
                f"{path}: {words} words exceeds the {ceiling}-word ceiling by "
                f"{words - ceiling}. Relocate content to the tier that owns it, or "
                f"condense it. Raising the ceiling is allowed but must be justified "
                f"in the PR (see AGENTS.md — Documentation budgets)."
            )

    print("\n".join(rows))

    if list_only:
        return 0

    if failures:
        print("\nverify-doc-budgets failed:\n", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    budgeted = sum(1 for key in manifest if not key.startswith("_"))
    print(f"\nverify-doc-budgets: {budgeted} budgeted docs within ceiling.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
