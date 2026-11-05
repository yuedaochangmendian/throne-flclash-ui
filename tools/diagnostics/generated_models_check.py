"""Consistency check for the checked-in Freezed output.

flutter/lib/ui/models.dart declares `@freezed` model classes, and
flutter/lib/ui/generated/models.freezed.dart is the generated companion that
`part` pulls in. The repository deliberately ships the generated file as-is:
pubspec.yaml has no build_runner / freezed dev dependency and pubspec.lock is
frozen for the CI AAR API scan, so there is no in-repo generation step.

This script is a static, dependency-free guard for that arrangement. It compares
the set of `@freezed` class names in models.dart with the model names behind the
generated `mixin _$X` / `class _X` declarations in models.freezed.dart. A new or
removed `@freezed` model without a regenerated companion fails the check.

Run from the repository root:
    python3 tools/diagnostics/generated_models_check.py

Exit code 0 when the two name sets match, 1 otherwise (missing/stale items are
printed). Nothing is generated or written; see generated/README.md for the
manual regeneration and review procedure.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MODELS = REPO_ROOT / "flutter" / "lib" / "ui" / "models.dart"
GENERATED = REPO_ROOT / "flutter" / "lib" / "ui" / "generated" / "models.freezed.dart"

# Each `@freezed` annotation is followed by the model's `class` declaration.
# Splitting on the annotation (with a word boundary so `@freezed_annotation`
# imports are not mistaken for one) and taking the first class name in each
# chunk keeps this to a shallow scan, not a Dart parser.
ANNOTATION_RE = re.compile(r"@freezed\b")
MODEL_CLASS_RE = re.compile(r"\bclass\s+([A-Za-z_$][\w$]*)")

# Freezed emits a private mixin (`mixin _$X`) and a private implementation
# (`class _X`) for each model X. The copyWith / pattern helpers use names with
# a leading `$` or a second `_`, so anchoring on a single `_` followed by a
# letter excludes them.
MIXIN_RE = re.compile(r"\bmixin\s+_\$([A-Za-z][\w$]*)\b")
IMPL_CLASS_RE = re.compile(r"\bclass\s+_([A-Za-z][\w$]*)\b")


def source_models(text: str) -> set[str]:
    names = set()
    for chunk in ANNOTATION_RE.split(text)[1:]:
        match = MODEL_CLASS_RE.search(chunk)
        if match:
            names.add(match.group(1))
    return names


def generated_models(text: str) -> set[str]:
    return set(MIXIN_RE.findall(text)) | set(IMPL_CLASS_RE.findall(text))


def main() -> int:
    for path in (MODELS, GENERATED):
        if not path.is_file():
            print(f"FAIL — {path.relative_to(REPO_ROOT)} is missing", file=sys.stderr)
            return 1

    source = source_models(MODELS.read_text(encoding="utf-8"))
    generated = generated_models(GENERATED.read_text(encoding="utf-8"))

    missing = sorted(source - generated)   # declared model with no generated companion
    stale = sorted(generated - source)     # generated shape with no declared model
    if missing or stale:
        print("FAIL — models.dart and models.freezed.dart are out of sync:")
        for name in missing:
            print(f"  missing generated mixin/implementation for: {name}")
        for name in stale:
            print(f"  generated shape without a @freezed source: {name}")
        print("Regenerate models.freezed.dart (see flutter/lib/ui/generated/README.md).")
        return 1

    print(f"generated models OK: {len(source)} @freezed model(s) match the generated shapes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
