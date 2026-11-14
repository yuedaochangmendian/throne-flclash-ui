#!/usr/bin/env python3
"""Keeps the Drift schema and its migration ladder honest.

`flutter/lib/database/` opens a SQLite file that outlives the app version, so the
schema version and the upgrade steps have to agree on every install, including the
one upgrading from a build that has not been run in months. Two skews are silent
in Dart and fatal in the field:

1. **A version without a step.** Bump `schemaVersion` past the highest `if (from <
   N)` in `migration` and an upgrading install runs no code for the new version:
   Drift stamps `user_version` to the new number and every query against the new
   column or table throws — but only on devices that upgraded, never on a fresh
   install, and never in a widget test.

2. **A step above the version.** An `if (from < N)` with N greater than
   `schemaVersion` can never run; it is dead code that reads as coverage. Either
   the version bump was forgotten or the step belongs to a release that never
   shipped.

The audit also checks that `schemaVersion` and the rung count are not accidentally
renumbered (a gap in the ladder is allowed — versions 7, 9, 11-16 were folded into
neighbouring steps — but a step *above* the declared version is not), and that the
generated Drift companion is wired into the same library the version lives in.
That last one is the migration-era replacement for this script's old job of
comparing two hand-written copies of a schema.

What the old version asserted, and why that is gone
--------------------------------------------------
It compared Room's schema to a *Dart reimplementation*: `@Database(version = N)` in
`SagerDatabase.kt` against `roomSchemaVersion` in `flutter/lib/data/db.dart`, with
a column-by-column audit of every `SELECT` in `flutter/lib/data/*_dao.dart` against
Room's exported `app/schemas/…/<N>.json`, plus a check that `db.dart`'s
`databaseFileName` matched `Key.DB_PROFILE`.

`flutter/lib/data/` was deleted by the FlClash UI migration and Dart no longer
reads Room's file at all: the FlClash UI owns its own Drift database
(`flutter/lib/database/database.dart`), Room still serves the Kotlin side through
its DAOs, and the two are separate stores with separate lifetimes. There is no
cross-language schema contract left to audit, so the checks were replaced with the
intra-Drift invariants above rather than deleted.

Run from the repository root:
    python3 tools/diagnostics/schema_audit.py

Exit code 0 when the version and the ladder agree, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATABASE_DART = ROOT / "flutter" / "lib" / "database" / "database.dart"
GENERATED = ROOT / "flutter" / "lib" / "database" / "generated" / "database.g.dart"

SCHEMA_VERSION_RE = re.compile(r"int\s+get\s+schemaVersion\s*=>\s*(\d+)\s*;")
UPGRADE_STEP_RE = re.compile(r"if\s*\(\s*from\s*<\s*(\d+)\s*\)")
DRIFT_ANNOTATION_RE = re.compile(r"@DriftDatabase\s*\(")
PART_RE = re.compile(r"^part\s+'([^']+)';", re.M)


def fail(message: str) -> None:
    print(f"::error::{message}")


def main() -> int:
    problems: list[str] = []

    if not DATABASE_DART.is_file():
        fail(f"missing {DATABASE_DART.relative_to(ROOT)}")
        return 1
    source = DATABASE_DART.read_text(encoding="utf-8")

    version_match = SCHEMA_VERSION_RE.search(source)
    if not version_match:
        problems.append("could not read `int get schemaVersion => N;` from database.dart")
        version = None
    else:
        version = int(version_match.group(1))

    steps = [int(value) for value in UPGRADE_STEP_RE.findall(source)]
    if not steps:
        problems.append(
            "no `if (from < N)` step found — either the migration was removed or it "
            "was rewritten in a shape this audit cannot read"
        )

    if version is not None and steps:
        highest = max(steps)
        if highest > version:
            problems.append(
                f"migration step `from < {highest}` is above schemaVersion {version}: "
                f"it can never run (forgot the version bump, or the step is stale)"
            )
        # Every declared version must have a rung. Gaps below the highest step are
        # historical (7, 9, 11-16 were folded in) and are fine; a hole at the top is
        # exactly the silent-upgrade failure this audit exists for.
        if version not in steps:
            below = sorted(step for step in steps if step <= version)
            problems.append(
                f"schemaVersion {version} has no `if (from < {version})` step "
                f"(highest rung is {highest}, rungs below the version are {below}). "
                f"An upgrading install would bump user_version without migrating."
            )

    if not DRIFT_ANNOTATION_RE.search(source):
        problems.append("database.dart no longer carries a @DriftDatabase(...) annotation")

    parts = PART_RE.findall(source)
    generated_parts = [part for part in parts if "generated" in part]
    if not generated_parts:
        problems.append(
            "database.dart does not `part` a generated file — the Drift companion is "
            "unwired and the schema tables would not compile"
        )
    for part in generated_parts:
        target = (DATABASE_DART.parent / part).resolve()
        if not target.is_file():
            problems.append(f"database.dart parts '{part}', which does not exist")

    # The generated companion has to describe the same table set the source declares;
    # anything else means one of the two was hand-edited.
    declared: set[str] = set()
    if GENERATED.is_file():
        generated = GENERATED.read_text(encoding="utf-8")
        declared = set(re.findall(
            r"\bclass\s+([A-Za-z_]\w*)\s+extends\s+Table\b",
            "\n".join(
                path.read_text(encoding="utf-8")
                for path in sorted(DATABASE_DART.parent.rglob("*.dart"))
                if "generated" not in path.relative_to(DATABASE_DART.parent).parts
            ),
        ))
        produced = set(re.findall(
            r"\bclass\s+\$([A-Za-z_]\w*)Table\s+extends\s+([A-Za-z_]\w*)\b", generated
        ))
        produced_tables = {table for _, table in produced}
        if declared != produced_tables:
            missing = sorted(declared - produced_tables)
            stale = sorted(produced_tables - declared)
            if missing:
                problems.append(f"database.g.dart has no table for: {', '.join(missing)}")
            if stale:
                problems.append(
                    f"database.g.dart generates tables with no source: {', '.join(stale)}"
                )
    else:
        problems.append(f"missing {GENERATED.relative_to(ROOT)}")

    if problems:
        for problem in problems:
            fail(problem)
        return 1

    print(
        f"schema OK: Drift schemaVersion {version}, rungs {sorted(set(steps))}, "
        f"{len(declared)} table(s) backed by the generated companion"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
