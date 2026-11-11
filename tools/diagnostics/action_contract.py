#!/usr/bin/env python3
"""Three-way contract audit for the Bettbox-style JSON action bus.

ADR 0002 replaced ADR 0001's typed-ABI-only stance with a single
`throne_invoke_action` entry point. The bus has three hand-written lists that
must agree by wire string:

  * Go    - `Method = "..."` constants in buildScript/core-patch/core/mobile/action.go
  * Go    - `register(MethodX, ...)` entries in the action dispatcher
  * Dart  - `ActionMethod` enum members in flutter/lib/core/action.dart

Bettbox itself keeps its Go constants and Dart enum in sync only by convention;
this repo measured a real drift there (`resetConnectionsMethod` vs
`resetConnections`, 72 vs 74 methods). A missing or misspelled method does not
fail to compile: the action falls through to `default` and silently returns
nothing. This audit is what makes that class of bug visible.

Phase 0 of ADR 0002 has no protocol files yet. In that state the audit reports
"not established" and exits 0, so it can be wired into CI before the bus lands;
once the files exist it becomes a hard gate.

Run from the repository root:  python3 tools/diagnostics/action_contract.py
Exit code 0 when every invariant holds, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GO_ACTION = ROOT / "buildScript" / "core-patch" / "core" / "mobile" / "action.go"
GO_BRIDGE = ROOT / "buildScript" / "core-patch" / "core" / "mobile" / "action_bridge.go"
DART_ACTION = ROOT / "flutter" / "lib" / "core" / "action.dart"

# A Go constant inside the Method const block. Two legal spellings:
#   `startSpeedTestMethod Method = "startSpeedTest"` (explicit type)
#   `startSpeedTestMethod      = "startSpeedTest"`  (type inherited, iota-free)
GO_CONST_RE = re.compile(
    r"""^\s*(\w+)\s*(?:Method\b)?\s*=\s*"([^"]+)"\s*,?\s*(?://.*)?$""", re.M
)
# Standalone `const fooMethod Method = "wire"`.
GO_STANDALONE_RE = re.compile(
    r"""^\s*const\s+(\w+)\s+Method\s*=\s*"([^"]+)"\s*(?://.*)?$""", re.M
)
# The dispatcher's registry: `register(methodFoo, ...)` or a map key.
GO_REGISTER_RE = re.compile(r"\bregister\(\s*(\w+)\s*,", re.M)
# Dart enum members, one per line: `  methodFoo,` (comments allowed).
DART_ENUM_RE = re.compile(r"^\s*([a-z][A-Za-z0-9]*)\s*,\s*(?://.*)?$", re.M)
DART_ENUM_BLOCK_RE = re.compile(r"enum\s+ActionMethod\s*\{(.*?)^\}", re.M | re.S)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def go_constants(text: str) -> dict[str, str]:
    """Map the Go identifier to the wire string it declares."""
    # Only the const block that declares Method values; other string constants in
    # the file (phase names, error codes) must not be treated as actions.
    block = re.search(r"const\s*\((.*?)^\)", text, re.M | re.S)
    if not block:
        return {}
    out: dict[str, str] = {}
    for name, wire in GO_CONST_RE.findall(block.group(1)):
        # Skip non-action constants that happen to live in the same block.
        if name.startswith(("action", "message")) and not name.endswith("Method"):
            continue
        out[name] = wire
    out.update(
        (name, wire) for name, wire in GO_STANDALONE_RE.findall(text)
    )
    return out


def dart_enum(text: str) -> set[str]:
    block = DART_ENUM_BLOCK_RE.search(text)
    if not block:
        return set()
    return set(DART_ENUM_RE.findall(block.group(1)))


def main() -> int:
    missing = [p for p in (GO_ACTION, GO_BRIDGE, DART_ACTION) if not p.exists()]
    if missing:
        names = ", ".join(str(p.relative_to(ROOT)) for p in missing)
        print(f"action bus not established yet (missing {names}); nothing to audit")
        return 0

    go_text, bridge_text, dart_text = (
        read(GO_ACTION),
        read(GO_BRIDGE),
        read(DART_ACTION),
    )
    constants = go_constants(go_text)
    registered = set(GO_REGISTER_RE.findall(go_text))
    # The bridge file may hold the registry instead of action.go.
    registered |= set(GO_REGISTER_RE.findall(bridge_text))
    dart = dart_enum(dart_text)

    failures: list[str] = []

    def check(ok: bool, message: str) -> None:
        if not ok:
            failures.append(message)

    print(
        f"Go constants: {len(constants)}   registered handlers: {len(registered)}   "
        f"Dart enum: {len(dart)}"
    )

    check(bool(constants), "no Method constants found in action.go")
    check(bool(dart), "no ActionMethod enum members found in action.dart")
    check(
        bool(registered),
        "no register(...) entries found; the dispatcher would answer every action "
        "with the default branch",
    )

    # Wire strings, not Go identifier names, are what crosses the C ABI.
    wires = set(constants.values())
    for label, actual in (("Dart enum", dart),):
        for key in sorted(wires - actual):
            failures.append(f"{label} is missing the Go wire value {key!r}")
        for key in sorted(actual - wires):
            failures.append(f"{label} declares {key!r} with no Go Method constant")

    # Every declared method must have a handler registered.
    identifiers = set(constants)
    for key in sorted(identifiers - registered):
        failures.append(f"Go constant {key!r} has no registered handler")
    for key in sorted(registered - identifiers):
        failures.append(f"registered handler {key!r} has no Method constant")

    # The Bettbox drift this audit exists to prevent: a wire name that differs
    # from its enum name by accident (both sides must use the identical string).
    for ident, wire in sorted(constants.items()):
        expected = ident[:-6] if ident.endswith("Method") else ident
        if wire != expected:
            failures.append(
                f"Go constant {ident!r} declares wire {wire!r}; expected {expected!r} "
                "(the Dart enum member is the wire name)"
            )

    if failures:
        for failure in failures:
            print(f"  FAIL: {failure}")
        return 1
    print("action contract OK: constants, handlers and Dart enum agree by wire name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
