#!/usr/bin/env python3
"""Keep docs/decisions/ and the module docs from drifting out of their indexes.

The split this enforces is the one docs/decisions/README.md describes: AGENTS.md
holds the invariant, a record holds what was tried and which belief turned out to
be wrong, and each side links to the other. Both halves of that promise rot
silently — a record nobody points at is a record nobody reads, and a hand-written
index is the "hand-restated catalog" failure mode by construction. It had already
happened twice when this gate was written: `h2c-upstream-stall.md` and
`tsan-local-runtime.md` were missing from the index, and three records carried no
back-link at all.

Four checks:

  1. Every record appears in the README index table.
  2. Every index row names a record that exists.
  3. Every record links back to the doc whose invariant it produced — a spec at
     the root, a module's own CLAUDE.md, or a skill.
  4. Every record is linked *from* one of those. An orphan is either dead or a
     link somebody forgot; both need a human, so both fail.

Skills count as homes because the relocation rule in AGENTS.md makes them one: an
invariant that is only wrong to not know while doing one task belongs in that
task's skill. This gate found the first such orphan the day that rule was applied
— the entitlements record, whose only inbound link had just moved to a skill.

It also checks the newer half of the same problem: a module `CLAUDE.md` is only
worth relocating into if it is *reachable*, so every one must be budgeted in
scripts/doc-budgets.json and linked from the root AGENTS.md. Six were created in
one session and wired up by hand; the seventh is the one that gets forgotten.

What it deliberately does not check: prose. A record's shape is free-form on
purpose — an incident reads differently from a rejected design from a
measurement — and a mandated `## Alternatives considered` heading would be
satisfied by an empty one. `scripts/verify-md-links.py` already proves the links
here resolve; this only proves they exist in both directions.

    scripts/verify-decision-records.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RECORDS = ROOT / "docs" / "decisions"
INDEX = RECORDS / "README.md"

# The root specs. A module CLAUDE.md and a skill are homes too — see below.
STANDING = ["AGENTS.md", "ROADMAP.md", "DESIGN.md", "INTERACTION.md"]

LINK_TARGET = re.compile(r"\]\(\s*<?([^)>\s]+)")


def link_targets(path: Path) -> set[str]:
    return set(LINK_TARGET.findall(path.read_text(encoding="utf-8")))


def main() -> int:
    records = sorted(p for p in RECORDS.glob("*.md") if p.name != "README.md")
    if not records:
        print("verify-decision-records: no records found — has the directory moved?",
              file=sys.stderr)
        return 1

    failures: list[str] = []

    indexed = {
        target.split("#", 1)[0]
        for target in link_targets(INDEX)
        if not target.startswith(("http", "..", "/"))
    }

    for record in records:
        if record.name not in indexed:
            failures.append(
                f"docs/decisions/{record.name}: not in the README index — "
                f"add a row naming the invariant it produced."
            )

    for target in sorted(indexed):
        if not (RECORDS / target).is_file():
            failures.append(f"docs/decisions/README.md: index row points at a missing "
                            f"record — {target}")

    # A record's back-link, and the standing doc's forward link.
    standing_paths = [ROOT / name for name in STANDING]
    standing_paths += sorted(ROOT.glob("*/CLAUDE.md")) + sorted(ROOT.glob("*/*/CLAUDE.md"))
    standing_paths += sorted(ROOT.glob(".github/CLAUDE.md"))
    standing_paths += sorted(ROOT.glob(".claude/skills/*/SKILL.md"))
    standing_paths += sorted(ROOT.glob(".claude/skills/*/references/*.md"))
    referenced: set[str] = set()
    for doc in standing_paths:
        if not doc.is_file():
            continue
        for target in link_targets(doc):
            name = target.split("#", 1)[0]
            if "docs/decisions/" in name:
                referenced.add(Path(name).name)

    for record in records:
        back = {
            Path(t.split("#", 1)[0]).name
            for t in link_targets(record)
        }
        if not any(name in back for name in STANDING) and not {"CLAUDE.md", "SKILL.md"} & back:
            failures.append(
                f"docs/decisions/{record.name}: no link back to the standing doc whose "
                f"invariant it produced (one of {', '.join(STANDING)}, or a module "
                f"CLAUDE.md). A record with no home reads as current guidance."
            )
        if record.name not in referenced:
            failures.append(
                f"docs/decisions/{record.name}: no standing doc links to it. Either an "
                f"invariant lost its record link, or the record is dead and should go."
            )

    # Module docs: budgeted and reachable.
    budgets = json.loads((ROOT / "scripts" / "doc-budgets.json").read_text(encoding="utf-8"))
    budgeted = {key for key in budgets if not key.startswith("_")}
    root_targets = {t.split("#", 1)[0] for t in link_targets(ROOT / "AGENTS.md")}

    module_docs = sorted(
        path.relative_to(ROOT).as_posix()
        for path in ROOT.rglob("CLAUDE.md")
        if ".build" not in path.parts and path.resolve() != (ROOT / "AGENTS.md").resolve()
    )
    for doc in module_docs:
        if doc not in budgeted:
            failures.append(
                f"{doc}: not in scripts/doc-budgets.json. A module doc absorbs relocated "
                f"content, so it needs a ceiling like any other standing doc."
            )
        if doc not in root_targets:
            failures.append(
                f"{doc}: the root AGENTS.md does not link to it. A module doc nobody can "
                f"find from the map is content that was moved out of reach, not relocated."
            )

    if failures:
        print("verify-decision-records failed:\n", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print(f"verify-decision-records: {len(records)} records and {len(module_docs)} module docs "
          f"indexed and cross-linked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
