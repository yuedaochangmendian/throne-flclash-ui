"""Check that every C library a cgo package includes is actually compiled in.

cgo compiles two things: the `.c` files sitting in the Go package directory, and
any `.c` a preamble `#include`s directly. A bare `#include "x.h"` plus an `-I`
flag makes only the *declarations* visible; the definitions stay out of the
shared object and the linker leaves them undefined. Android does not refuse an
.so with undefined symbols at build time, so the failure lands on the device at
`dlopen`:

    UnsatisfiedLinkError: dlopen failed: cannot locate symbol "sqlite3_open_v2"

That happened here: PR #63 put the SQLite amalgamation in `mobile/sqlite3/` and
added `-I${SRCDIR}/sqlite3`. Every CI job stayed green while three prereleases
shipped unlaunchable. This is the gate that would have caught it.

A package passes when, for each `#include "name.h"` whose `name.c` this
repository ships, either

  * `name.c` sits in the package directory (cgo compiles it), or
  * the preamble `#include`s `name.c` itself (cgo compiles what it includes).

Anything else means the symbols are declared and never defined.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "buildScript" / "core-patch" / "core" / "mobile"

PREAMBLE = re.compile(r"package \w+\s*\n\n/\*(.*?)\*/", re.S)
HEADER = re.compile(r'\s*#include\s+"([^"]+)"')


def cgo_packages(patch: Path) -> dict[Path, list[str]]:
    """Map each directory holding cgo code to all of its preambles.

    Every preamble matters: a package usually has several cgo files, and the one
    that includes a given header is not necessarily the first by filename.
    """
    found: dict[Path, list[str]] = {}
    for go_file in sorted(patch.rglob("*.go")):
        if go_file.name.endswith("_test.go"):
            continue
        text = go_file.read_text(encoding="utf-8", errors="replace")
        m = PREAMBLE.search(text)
        if not m:
            continue
        if any(line.strip().startswith("#cgo") for line in m.group(1).splitlines()):
            found.setdefault(go_file.parent, []).append(m.group(1))
    return found


def includes(preamble: str) -> list[str]:
    """Every `#include "..."` in a preamble, in order."""
    return [m.group(1) for m in (HEADER.match(line) for line in preamble.splitlines()) if m]


def check(patch: Path) -> tuple[list[str], int]:
    problems: list[str] = []
    checked = 0
    for directory, preambles in cgo_packages(patch).items():
        # What cgo will compile: everything any preamble #includes directly.
        included_names: set[str] = set()
        for preamble in preambles:
            included_names.update(Path(name).name for name in includes(preamble))
        for header in sorted({name for p in preambles for name in includes(p)}):
            shipped = list(directory.rglob(Path(header).name))
            if not shipped:
                # A platform or third-party header with no companion here.
                continue
            source_name = Path(header).with_suffix(".c").name
            companions = list(directory.rglob(source_name))
            if not companions:
                # Declaration-only header (macros, inline code, types).
                continue
            checked += 1
            if source_name in included_names:
                print(f"{directory.name}: {source_name} is #included by a preamble (OK)")
                continue
            if any(path.parent == directory for path in companions):
                print(f"{directory.name}: {source_name} is in the package directory (OK)")
                continue
            where = companions[0].relative_to(directory).as_posix()
            problems.append(
                f"{directory.name}: {header} is included but {source_name} lives in "
                f"{where}. cgo compiles only the package directory's .c files and "
                f"what a preamble #includes directly, so those definitions never "
                f"reach the .so — the app fails at dlopen with an "
                f"UnsatisfiedLinkError. Move it beside the .go files, or #include "
                f"the .c from a preamble."
            )
    return problems, checked


def main() -> int:
    problems, checked = check(PATCH)
    for problem in problems:
        print(f"FAIL: {problem}")
    if problems:
        return 1
    if checked == 0:
        print("no cgo package ships a C library here; nothing to check")
    print(f"cgo C linkage OK: {checked} header/source pair(s) checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
