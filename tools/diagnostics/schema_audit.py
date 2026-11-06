#!/usr/bin/env python3
"""Keeps Dart's copy of the schema version honest.

`flutter/lib/data/` reads Room's file directly, which means it also depends on
Room's schema without being checked by it. The one failure mode that has no
symptom is a version skew: bump `@Database(version = …)` in SagerDatabase.kt and
leave `roomSchemaVersion` in db.dart alone, and every query keeps working — it
just reads columns by name from a table whose shape moved, returning the wrong
field instead of failing. `DataDatabase._checkSchema` catches this at runtime by
refusing to open, but a refusal on a user's phone is a bug report; this catches
it on push.

Also checks that the file name matches `Key.DB_PROFILE`, because a rename there
would make Dart open a fresh empty file — which `openAt` creates, since the write
path passes SQLITE_OPEN_CREATE.

Run from the repository root:
    python3 tools/diagnostics/schema_audit.py

Exit code 0 when the two sides agree, 1 otherwise.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

DATABASE_KT = ROOT / "app/src/main/java/io/nekohasekai/sagernet/database/SagerDatabase.kt"
CONSTANTS_KT = ROOT / "app/src/main/java/io/nekohasekai/sagernet/Constants.kt"
DB_DART = ROOT / "flutter/lib/data/db.dart"


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing file: {path.relative_to(ROOT)}")
        raise


def fail(message: str) -> None:
    print(f"::error::{message}")


def annotation_body(source: str) -> str | None:
    """The text inside `@Database(...)`, found by balancing parentheses.

    `@Database\\s*\\((.*?)\\)` stops at the first `)`, which may belong to a
    nested call (`AutoMigration(from = 1, to = 2)`). That would truncate the
    body and could hide `version` entirely. Count the nesting instead.
    """
    match = re.search(r"@Database\s*\(", source)
    if not match:
        return None
    depth = 1
    for index in range(match.end(), len(source)):
        char = source[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[match.end():index]
    return None


def main() -> int:
    problems = []

    database_kt = read(DATABASE_KT)
    constants_kt = read(CONSTANTS_KT)
    db_dart = read(DB_DART)

    # The @Database annotation: `version = 19,` inside the annotation's parentheses.
    body = annotation_body(database_kt)
    if body is None:
        problems.append("could not find a balanced @Database(...) in SagerDatabase.kt")
        room_version = None
    else:
        version_match = re.search(r"\bversion\s*=\s*(\d+)", body)
        if not version_match:
            problems.append("could not read `version = N` from @Database")
            room_version = None
        else:
            room_version = int(version_match.group(1))

    dart_match = re.search(r"roomSchemaVersion\s*=\s*(\d+)", db_dart)
    dart_version = int(dart_match.group(1)) if dart_match else None
    if dart_version is None:
        problems.append("could not read `roomSchemaVersion = N` from flutter/lib/data/db.dart")

    if room_version is not None and dart_version is not None and room_version != dart_version:
        problems.append(
            f"schema version skew: SagerDatabase.kt is at {room_version}, "
            f"flutter/lib/data/db.dart says {dart_version}. "
            f"Bump roomSchemaVersion (and update the DAOs for any column that moved)."
        )

    db_name_match = re.search(r'DB_PROFILE\s*=\s*"([^"]+)"', constants_kt)
    kotlin_name = db_name_match.group(1) if db_name_match else None
    if kotlin_name is None:
        problems.append("could not read DB_PROFILE from Constants.kt")

    dart_name_match = re.search(r"databaseFileName\s*=\s*'([^']+)'", db_dart)
    dart_name = dart_name_match.group(1) if dart_name_match else None
    if dart_name is None:
        problems.append("could not read `databaseFileName` from flutter/lib/data/db.dart")

    if kotlin_name and dart_name and kotlin_name != dart_name:
        problems.append(
            f"database name mismatch: Key.DB_PROFILE is {kotlin_name!r}, "
            f"db.dart says {dart_name!r}"
        )

    if problems:
        for problem in problems:
            fail(problem)
        return 1

    print(
        f"schema OK: version {room_version}, file {dart_name!r}, "
        f"Dart and Room agree"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
