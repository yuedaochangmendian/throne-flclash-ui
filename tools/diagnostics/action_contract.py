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
# Method constants live next to their domain: action.go (bus core), route_actions.go
# (routing), speedtest in action.go. Every hand-written Go file in the patch is scanned so
# a new domain does not have to remember to register itself here.
GO_ACTION_DIR = ROOT / "buildScript" / "core-patch" / "core" / "mobile"
# The C entry point lives in the generated runtime (bindgen.py's
# emit_go_runtime), not in a hand-written bridge file.
GO_BRIDGE = ROOT / "buildScript" / "core-patch" / "core" / "mobile" / "bridge_runtime.go"
DART_ACTION = ROOT / "flutter" / "lib" / "core" / "action.dart"

# A push event's method tag. It is posted without an id and has no handler;
# requiring one would be a false positive.
PUSH_ONLY_METHODS = {"messageMethod"}

# Only a constant DECLARED as a Method is an action:
#   `startSpeedTestMethod Method = "startSpeedTest"`
# The patch is full of other string constants (speedTestPhaseLatency = "latency",
# speedTestProviderApple = "apple", …) whose name is not the wire value, so matching every
# string constant in a const block produced false drift reports the moment the scan widened
# beyond action.go. Requiring the explicit type is the only reliable discriminator.
GO_CONST_RE = re.compile(
    r"""^\s*(\w+)\s+Method\s*=\s*"([^"]+)"\s*,?\s*(?://.*)?$""", re.M
)
# A block whose members inherit the type from the first line.
GO_CONST_INHERIT_RE = re.compile(
    r"""^\s*(\w+)\s*=\s*"([^"]+)"\s*,?\s*(?://.*)?$""", re.M
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
    """Map each `X Method = "wire"` identifier to the wire string it declares.

    Every const block in the file is scanned, not just the first: a domain keeps its
    Method constants beside its handlers, and `route_actions.go` opens with the
    outbound-id block before the method block. Only constants with the explicit
    `Method` type count — the patch also holds speedTestPhaseLatency = "latency",
    speedTestProviderApple = "apple" and similar, whose names are not wire values.
    """
    out: dict[str, str] = dict(GO_STANDALONE_RE.findall(text))
    for block in re.findall(r"const\s*\((.*?)^\)", text, re.M | re.S):
        out.update(dict(GO_CONST_RE.findall(block)))
        # A block that starts typed may continue with the type inherited.
        typed = False
        for entry in block.split("\n"):
            if re.search(r"\w+\s+Method\s*=", entry):
                typed = True
                continue
            if typed:
                match = GO_CONST_INHERIT_RE.match(entry)
                if match:
                    out[match.group(1)] = match.group(2)
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
    # Scan every hand-written Go file in the patch: a domain keeps its Method constants
    # beside its handlers, so `route_actions.go` must count as much as `action.go`.
    domain_texts = [
        read(path)
        for path in sorted(GO_ACTION_DIR.glob("*.go"))
        if "DO NOT EDIT" not in read(path)[:200]
    ]
    constants: dict[str, str] = {}
    registered: set[str] = set()
    for text in domain_texts:
        constants.update(go_constants(text))
        registered |= set(GO_REGISTER_RE.findall(text))
    # The generated runtime may hold the registry instead of action.go.
    registered |= set(GO_REGISTER_RE.findall(bridge_text))
    requests = {
        k: v for k, v in constants.items() if k not in PUSH_ONLY_METHODS
    }
    dart = dart_enum(dart_text)

    failures: list[str] = []

    def check(ok: bool, message: str) -> None:
        if not ok:
            failures.append(message)

    print(
        f"Go constants: {len(constants)} ({len(requests)} requests)   "
        f"registered handlers: {len(registered)}   Dart enum: {len(dart)}"
    )

    check(bool(requests), "no request Method constants found in action.go")
    check(bool(dart), "no ActionMethod enum members found in action.dart")
    check(
        bool(registered),
        "no register(...) entries found; the dispatcher would answer every action "
        "with the default branch",
    )

    # Wire strings, not Go identifier names, are what crosses the C ABI.
    # Push-only tags (message) are excluded: Dart receives them as events,
    # never as an ActionMethod it can invoke.
    wires = set(requests.values())
    for key in sorted(wires - dart):
        failures.append(f"Dart enum is missing the Go wire value {key!r}")
    for key in sorted(dart - wires):
        failures.append(f"Dart enum declares {key!r} with no Go Method constant")

    # Every declared request method must have a handler registered.
    identifiers = set(requests)
    for key in sorted(identifiers - registered):
        failures.append(f"Go constant {key!r} has no registered handler")
    for key in sorted(registered - identifiers):
        failures.append(f"registered handler {key!r} has no Method constant")

    # The Bettbox drift this audit exists to prevent: a wire name that differs
    # from its enum name by accident (both sides must use the identical string).
    for ident, wire in sorted(requests.items()):
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
