#!/usr/bin/env python3
"""Three-way contract audit for the throne_* C ABI.

The self-owned bridge is split across three generated artifacts that used to be
kept in sync by hand:

  * Go  - `//export throne_*` in buildScript/core-patch/core/mobile/*.go
  * C   - declarations in both copies of bridge_symbols.h
  * Dart- `_lookup('throne_*')` in flutter/lib/core/throne_ffi.dart

A missing declaration is a link error; a stale one is a runtime crash. This
audit also enforces the FFI hardening rules that are easy to lose when the
generated files are refreshed:

  * every export has a recover() fence (a Go panic crossing cgo aborts the app)
  * no panic() remains in the bridge Go files
  * wrapper classes attach a finalizer and expose an explicit release()
  * generated bindings are excluded from analysis, not blanket-waived
  * the generator templates still know about the runtime-only exports

Run from the repository root:  python3 tools/diagnostics/symbol_audit.py
Exit code 0 when every invariant holds, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "buildScript" / "core-patch" / "core" / "mobile"
HEADERS = [
    PATCH / "bridge_symbols.h",
    ROOT / "android" / "core" / "src" / "main" / "cpp" / "bridge_symbols.h",
]
GO_FILES = [PATCH / "bridge_calls.go", PATCH / "bridge_runtime.go", PATCH / "dartbridge.go"]
DART = ROOT / "flutter" / "lib" / "core" / "throne_ffi.dart"
GENERATOR = ROOT / "tools" / "bindgen" / "bindgen.py"
ANALYSIS = ROOT / "flutter" / "analysis_options.yaml"

EXPORT_RE = re.compile(r"^//export (throne_\w+)\s*$", re.M)
HEADER_RE = re.compile(r"^\s*[\w ]+?\s*\*?\s*(throne_\w+)\s*\([^;]*\);\s*$", re.M)
LOOKUP_RE = re.compile(r"_lookup<.*?>\('(throne_\w+)'\)")
CLASS_RE = re.compile(r"^class (Throne\w+) \{$", re.M)


def main() -> int:
    failures: list[str] = []

    def check(ok: bool, message: str) -> None:
        if not ok:
            failures.append(message)

    go_texts = [p.read_text(encoding="utf-8") for p in GO_FILES]
    go_exports: set[str] = set()
    for text in go_texts:
        go_exports.update(EXPORT_RE.findall(text))

    header_texts = [p.read_text(encoding="utf-8") for p in HEADERS]
    check(header_texts[0] == header_texts[1], "the two bridge_symbols.h copies differ")
    header_symbols = set(HEADER_RE.findall(header_texts[0]))

    dart_text = DART.read_text(encoding="utf-8")
    dart_symbols = set(LOOKUP_RE.findall(dart_text))

    print(f"Go //export: {len(go_exports)}   C declarations: {len(header_symbols)}   "
          f"Dart lookups: {len(dart_symbols)}")

    for label, missing, extra in (
        ("C header", sorted(go_exports - header_symbols), sorted(header_symbols - go_exports)),
        ("Dart", sorted(go_exports - dart_symbols), sorted(dart_symbols - go_exports)),
    ):
        if missing:
            failures.append(f"{label} is missing {len(missing)} exports: {', '.join(missing[:12])}")
        if extra:
            failures.append(f"{label} declares {len(extra)} symbols with no Go export: {', '.join(extra[:12])}")

    # Every export must be fenced. cgo cannot propagate a Go panic.
    #
    # Two fences are legitimate: guardExport (reports the panic on the typed error
    # channel) and a local recover (the heartbeat reads, whose panic must not reach
    # that channel — the next Instance.start would read it as its own failure).
    for path, text in zip((GO_FILES[0], GO_FILES[1]), go_texts[:2]):
        lines = text.split("\n")
        for idx, line in enumerate(lines[:-1]):
            m = EXPORT_RE.match(line)
            if not m:
                continue
            name = m.group(1)
            following = "\n".join(lines[idx + 1:idx + 4])
            fenced = (f'defer guardExport("{name}")' in following
                      or ("defer func()" in following and "recover()" in following))
            if not fenced:
                failures.append(f"{path.name}: {name} has no recover() fence")

    for path, text in zip(GO_FILES, go_texts):
        if re.search(r"\bpanic\(", text):
            failures.append(f"{path.name}: panic() can cross the cgo boundary")

    # Wrappers: explicit release plus a GC fallback.
    class_blocks = list(CLASS_RE.finditer(dart_text))
    print(f"Dart wrapper classes: {len(class_blocks)}")
    for i, match in enumerate(class_blocks):
        end = class_blocks[i + 1].start() if i + 1 < len(class_blocks) else len(dart_text)
        block = dart_text[match.start():end]
        name = match.group(1)
        if name == "ThroneFFI":  # raw lookup table, owns no handles
            continue
        if "_handleFinalizer.attach(" not in block:
            failures.append(f"{name}: no finalizer attached in constructor")
        if "void release() =>" not in block:
            failures.append(f"{name}: no explicit release()")

    check("ignore_for_file:" not in dart_text,
          "throne_ffi.dart still carries blanket lint waivers")
    check("lib/core/throne_ffi.dart" in ANALYSIS.read_text(encoding="utf-8"),
          "analysis_options.yaml does not exclude the generated bindings")

    generator = GENERATOR.read_text(encoding="utf-8")
    for symbol in ("throne_status_snapshot", "throne_handle_stats"):
        check(symbol in generator, f"bindgen.py does not declare {symbol}")
    check("def _guard_exports(" in generator,
          "bindgen.py does not emit recover() fences for runtime exports")

    if failures:
        print(f"\nFAIL — {len(failures)} problem(s):")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("\ncontract OK: Go exports == C declarations == Dart lookups; "
          "all exports fenced, all wrappers releasable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
