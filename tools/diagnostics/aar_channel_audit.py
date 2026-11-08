#!/usr/bin/env python3
"""Audits the `io.flrone/*` channel surface of binary artifacts and Dart string literals.

`channel_audit.py` keeps the method channel's *methods* in step from the two source trees, but
anything that lives in a binary is invisible to it: a vendored AAR can register a platform view
or open a channel of its own, and the only trace is a string in its classes (the pre.19 note:
the view channels `io.flrone/ghostty|openconnect|terminal` had no in-repo counterpart to audit).
This scan makes that surface visible and bounded:

  1. every `io.flrone/...` string in the given .aar / .jar / .apk / .dex binaries must match
     `tools/diagnostics/aar_channels.txt` (a plain budget of allowed channel names, one pattern
     per line, `*` a trailing wildcard);
  2. every `'io.flrone/...'` string literal under `flutter/lib` must match the same budget, so a
     new view type or channel cannot appear on the Dart side without an entry either.

An unknown channel fails the run; a budget entry nothing references is only reported (the
budget names dormant channels on purpose — see the comments in the file).

Run from the repository root:
    python3 tools/diagnostics/aar_channel_audit.py [<aar-or-jar-or-apk-or-dex> ...]

Exit code 0 when the surface is inside the budget, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BUDGET = Path(__file__).with_name("aar_channels.txt")

CHANNEL = re.compile(rb"io\.flrone/[A-Za-z0-9_./$-]{1,60}")
DART_LITERAL = re.compile(r"""['"](io\.flrone/[A-Za-z0-9_./$-]{1,60})['"]""")


def load_budget() -> list[tuple[str, str]]:
    patterns = []
    for raw in BUDGET.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            patterns.append((line, raw.strip()))
    if not patterns:
        sys.exit(f"::error::{BUDGET} is empty")
    return patterns


def matches(name: str, pattern: str) -> bool:
    if pattern.endswith("*"):
        return name.startswith(pattern[:-1])
    return name == pattern


def scan_bytes(data: bytes, where: str, found: dict[str, set[str]]) -> None:
    for m in CHANNEL.finditer(data):
        found.setdefault(m.group(0).decode(), set()).add(where)


def scan_binary(path: Path, found: dict[str, set[str]]) -> None:
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            for entry in z.infolist():
                if entry.is_dir():
                    continue
                data = z.read(entry)
                scan_bytes(data, f"{path.name}:{entry.filename}", found)
                # a .jar inside an .aar: its .class constant pools
                if entry.filename.endswith(".jar") and zipfile.is_zipfile(io_bytes(data)):
                    with zipfile.ZipFile(io_bytes(data)) as inner:
                        for sub in inner.infolist():
                            if not sub.is_dir():
                                scan_bytes(inner.read(sub), f"{path.name}:{entry.filename}:{sub.filename}", found)
    else:
        scan_bytes(path.read_bytes(), path.name, found)


def io_bytes(data: bytes):
    import io
    return io.BytesIO(data)


def main(argv: list[str]) -> int:
    budget = load_budget()
    found: dict[str, set[str]] = {}

    for dart in sorted((REPO_ROOT / "flutter" / "lib").rglob("*.dart")):
        for m in DART_LITERAL.finditer(dart.read_text()):
            found.setdefault(m.group(1), set()).add(str(dart.relative_to(REPO_ROOT)))

    for arg in argv:
        path = Path(arg)
        if not path.exists():
            sys.exit(f"::error::{path} does not exist")
        scan_binary(path, found)

    unknown = sorted(n for n in found if not any(matches(n, p) for p, _ in budget))
    unused = [raw for p, raw in budget if not any(matches(n, p) for n in found)]

    print(f"channel surface: {len(found)} name(s) referenced")
    for name in sorted(found):
        print(f"  {name}  <- {len(found[name])} site(s)")
    if unused:
        print(f"budget entries nothing references ({len(unused)}):")
        for raw in unused:
            print(f"  {raw}")

    if unknown:
        print(f"::error::{len(unknown)} channel name(s) outside the budget "
              f"({BUDGET.relative_to(REPO_ROOT)}):")
        for name in unknown:
            sites = ", ".join(sorted(found[name])[:3])
            print(f"  {name}  <- {sites}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
