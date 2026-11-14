"""Consistency check for the checked-in build_runner output.

The FlClash UI ships generated code in the tree: Freezed models under
`flutter/lib/models/generated/`, Riverpod providers under
`flutter/lib/providers/generated/`, and the Drift database under
`flutter/lib/database/generated/`. `build_runner` IS a dev dependency here, but
regenerating on every CI run would make the gate depend on codegen determinism
and on a `pub get` that resolves the whole graph; this script is the cheap static
stand-in that catches the failure mode which actually bites — a source file and
its generated companion drifting apart — without running anything.

Three checks, all dependency-free:

1. **Freezed shape.** For each `@freezed` source file, the model classes it
   declares must have exactly the `mixin _$X` / `class _X` companions in its
   `part 'generated/*.freezed.dart'` file. A new or renamed model without a
   regenerated companion fails here — and it would fail at compile time anyway,
   but as a `_$X` undefined error a hundred lines into a generated file.

2. **Part wiring.** Every `part '…generated/…';` directive must resolve, and every
   file under a `generated/` directory must be pulled in by some `part` of a
   non-generated source file. An orphaned generated file is dead weight that the
   analyzer cannot see (it is excluded) and that a reviewer cannot judge.

3. **Drift tables.** Every `class X extends Table` under `flutter/lib/database/`
   must have a `$XTable` in `database.g.dart`, and vice versa. A table added
   without regenerating makes `Database` fail to compile; a table removed without
   regenerating leaves a generated shape whose column list no longer matches the
   schema the app opens files with.

What the old version asserted, and why that is gone
--------------------------------------------------
It compared `flutter/lib/ui/models.dart` against
`flutter/lib/ui/generated/models.freezed.dart` and asserted in its docstring that
`pubspec.yaml` had no `build_runner`/`freezed` dev dependency and that `pubspec.lock`
was frozen for the CI AAR API scan. All three statements were inverted by the
FlClash UI migration: `ui/` no longer holds models, the generated tree moved under
`lib/models|providers|database/generated/`, and `build_runner ^2.16.1` plus
`freezed ^4.0.1` are now real dev dependencies (see the `build.yaml` targets that
pin those output paths). The premise is inverted, so the check was rewritten
against the layout that exists instead of being deleted.

Run from the repository root:
    python3 tools/diagnostics/generated_models_check.py

Exit code 0 when every name set matches, 1 otherwise (mismatches are printed).
Nothing is generated or written; regenerate with
`dart run build_runner build --delete-conflicting-outputs` from `flutter/`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FLUTTER_LIB = REPO_ROOT / "flutter" / "lib"
DATABASE = FLUTTER_LIB / "database"

# Each `@freezed` annotation is followed by the model's `class` declaration.
# Splitting on the annotation (with a word boundary so `@freezed_annotation`
# imports are not mistaken for one) and taking the first class name in each
# chunk keeps this to a shallow scan, not a Dart parser. Both spellings are
# accepted: the bare `@freezed` and the parameterised `@Freezed(toStringOverride:
# false)` two source files use (`@freezed` is the const instance of the same
# class, so the generated output is identical).
ANNOTATION_RE = re.compile(r"@[Ff]reezed\b")
MODEL_CLASS_RE = re.compile(r"\bclass\s+([A-Za-z_$][\w$]*)")
# Freezed emits a private mixin (`mixin _$X`) and a private implementation
# (`class _X`) for each model X. Anchoring on a single `_` followed by a letter
# excludes `copyWith` helpers and the `_$XCopyWith` family.
MIXIN_RE = re.compile(r"\bmixin\s+_\$([A-Za-z][\w$]*)\b")
IMPL_CLASS_RE = re.compile(r"\bclass\s+_([A-Za-z][\w$]*)\b")

PART_RE = re.compile(r"^part\s+'([^']+)';", re.M)
DRIFT_TABLE_RE = re.compile(r"\bclass\s+([A-Za-z_]\w*)\s+extends\s+Table\b")
DRIFT_GENERATED_RE = re.compile(r"\bclass\s+\$([A-Za-z_]\w*)Table\s+extends\s+([A-Za-z_]\w*)\b")


def source_models(text: str) -> set[str]:
    names = set()
    for chunk in ANNOTATION_RE.split(text)[1:]:
        match = MODEL_CLASS_RE.search(chunk)
        if match:
            names.add(match.group(1))
    return names


def generated_models(text: str) -> set[str]:
    return set(MIXIN_RE.findall(text)) | set(IMPL_CLASS_RE.findall(text))


def is_generated(path: Path) -> bool:
    return "generated" in path.relative_to(FLUTTER_LIB).parts


def freezed_problems() -> list[str]:
    problems: list[str] = []
    for source in sorted(FLUTTER_LIB.rglob("*.dart")):
        if is_generated(source):
            continue
        text = source.read_text(encoding="utf-8")
        if "@freezed" not in text and "@Freezed" not in text:
            continue
        parts = [source.parent / part for part in PART_RE.findall(text)
                 if part.endswith("freezed.dart")]
        if not parts:
            problems.append(
                f"{source.relative_to(REPO_ROOT)} has @freezed models but no "
                f"part 'generated/*.freezed.dart' directive"
            )
            continue
        declared = source_models(text)
        generated: set[str] = set()
        for part in parts:
            if not part.is_file():
                problems.append(
                    f"{source.relative_to(REPO_ROOT)} parts {part.name}, which does not exist"
                )
                continue
            generated |= generated_models(part.read_text(encoding="utf-8"))
        missing = sorted(declared - generated)
        stale = sorted(generated - declared)
        if missing:
            problems.append(
                f"{source.relative_to(REPO_ROOT)}: {len(missing)} model(s) with no generated "
                f"companion: {', '.join(missing)}"
            )
        if stale:
            problems.append(
                f"{source.relative_to(REPO_ROOT)}: {len(stale)} generated shape(s) with no "
                f"@freezed source: {', '.join(stale)}"
            )
    return problems


def part_wiring_problems() -> list[str]:
    problems: list[str] = []
    claimed: set[Path] = set()
    for source in sorted(FLUTTER_LIB.rglob("*.dart")):
        if is_generated(source):
            continue
        for part in PART_RE.findall(source.read_text(encoding="utf-8")):
            target = (source.parent / part).resolve()
            if not target.is_file():
                problems.append(
                    f"{source.relative_to(REPO_ROOT)} parts '{part}', which does not exist"
                )
                continue
            claimed.add(target)
    for generated in sorted(FLUTTER_LIB.rglob("generated/*.dart")):
        if generated.resolve() not in claimed:
            problems.append(
                f"{generated.relative_to(REPO_ROOT)} is not pulled in by any part directive"
            )
    return problems


def drift_problems() -> list[str]:
    problems: list[str] = []
    generated = DATABASE / "generated" / "database.g.dart"
    if not generated.is_file():
        return [f"{generated.relative_to(REPO_ROOT)} is missing"]
    declared: set[str] = set()
    for source in sorted(DATABASE.rglob("*.dart")):
        if is_generated(source):
            continue
        declared |= set(DRIFT_TABLE_RE.findall(source.read_text(encoding="utf-8")))
    produced = {table for _, table in DRIFT_GENERATED_RE.findall(
        generated.read_text(encoding="utf-8"))}
    missing = sorted(declared - produced)
    stale = sorted(produced - declared)
    if missing:
        problems.append(
            f"database.g.dart has no table for: {', '.join(missing)} "
            f"(run build_runner)"
        )
    if stale:
        problems.append(
            f"database.g.dart generates tables with no `extends Table` source: "
            f"{', '.join(stale)}"
        )
    return problems


def count_freezed_files() -> int:
    return sum(
        1 for path in FLUTTER_LIB.rglob("*.dart")
        if not is_generated(path)
        and ("@freezed" in (text := path.read_text(encoding="utf-8"))
             or "@Freezed" in text)
    )


def main() -> int:
    problems = freezed_problems() + part_wiring_problems() + drift_problems()
    if problems:
        print("FAIL — the checked-in generated code is out of sync:")
        for problem in problems:
            print(f"  - {problem}")
        print(
            "\nRegenerate with `dart run build_runner build --delete-conflicting-outputs` "
            "from flutter/, then commit the diff."
        )
        return 1

    generated_files = sum(1 for _ in FLUTTER_LIB.rglob("generated/*.dart"))
    print(
        f"generated code OK: {count_freezed_files()} @freezed source file(s) match their "
        f"companions, {generated_files} generated file(s) are all `part`-wired, and every "
        f"Drift table has a generated one"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
