#!/usr/bin/env python3
"""Contract audit for the throne_* C ABI — Go exports against the C header.

The self-owned bridge is split across generated artifacts that used to be kept in
sync by hand, and drift between them is a link error or a runtime crash with no
compiler diagnostic anywhere:

  * Go  — `//export throne_*` in buildScript/core-patch/core/mobile/*.go
  * C   — declarations in both copies of bridge_symbols.h
          (the core patch, and the copy the Android JNI shim compiles against)

The audit also enforces the FFI hardening rules that are easy to lose when the
generated files are refreshed:

  * every export has a recover() fence (a Go panic crossing cgo aborts the app)
  * no panic() remains in the bridge Go files
  * the two bridge_symbols.h copies are byte-identical
  * the generator templates still know about the runtime-only exports

What this script no longer checks, and why
------------------------------------------
Until the FlClash UI migration the audit was three-way: it also compared the C ABI
against the generated Dart bindings (`flutter/lib/core/throne_ffi.dart`, i.e. one
`_lookup<…>('throne_*')` per export plus a finalizer and an explicit `release()`
per wrapper class) and asserted that `flutter/analysis_options.yaml` excluded that
file from analysis.

Both halves of that contract are gone and nothing replaced them: the FlClash UI
reaches the kernel through its own Kotlin path (`com.follow.clash.plugins` →
`ThroneCore`), and `flutter/lib/core/` was deleted wholesale. The C ABI itself is
still shipped and still load-bearing — `android/core/src/main/cpp/core.cpp` calls
straight into `throne_start_tun`, `throne_suspend`, … — so the Go/C/link half is
kept unchanged and the Dart half is dropped rather than re-pointed at a file that
no longer exists. `tools/bindgen/bindgen.py` can still emit a Dart binding, but no
build in this repository consumes one, so auditing its shape would assert a
contract with no second end.

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
GENERATOR = ROOT / "tools" / "bindgen" / "bindgen.py"

EXPORT_RE = re.compile(r"^//export (throne_\w+)\s*$", re.M)
HEADER_RE = re.compile(r"^\s*[\w ]+?\s*\*?\s*(throne_\w+)\s*\([^;]*\);\s*$", re.M)

# Runtime-only exports the generator emits from templates rather than from a plain
# `//export` line in the mobile Go files; the generator must still know them.
RUNTIME_EXPORTS = ("throne_status_snapshot", "throne_handle_stats")


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

    print(f"Go //export: {len(go_exports)}   C declarations: {len(header_symbols)}")

    missing = sorted(go_exports - header_symbols)
    extra = sorted(header_symbols - go_exports)
    if missing:
        failures.append(f"C header is missing {len(missing)} exports: {', '.join(missing[:12])}")
    if extra:
        failures.append(
            f"C header declares {len(extra)} symbols with no Go export: {', '.join(extra[:12])}"
        )

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

    generator = GENERATOR.read_text(encoding="utf-8")
    for symbol in RUNTIME_EXPORTS:
        check(symbol in generator, f"bindgen.py does not declare {symbol}")
    check("def _guard_exports(" in generator,
          "bindgen.py does not emit recover() fences for runtime exports")

    if failures:
        print(f"\nFAIL — {len(failures)} problem(s):")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("\ncontract OK: Go exports == C declarations in both header copies; "
          "all exports fenced, no panic() crossings, generator templates intact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
