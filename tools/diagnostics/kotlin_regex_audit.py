#!/usr/bin/env python3
"""Guard against regex patterns that compile on the JVM but not on Android.

Android delegates java.util.regex.Pattern to ICU (com.android.icu.util.regex
.PatternNative), which rejects a lone unescaped `}` with U_REGEX_RULE_SYNTAX.
The JVM's Pattern accepts that as a literal, so a Kotlin compile and a JVM unit
test both pass while the service crashes on a real device (3.3.1-pre.17:
ServiceNotification.<clinit> -> ExceptionInInitializerError on onStartCommand).

This audit scans Regex(...) string literals in app/src and fails on that shape.
It deliberately checks literals only: patterns assembled at runtime from
variables cannot be reasoned about statically and are out of scope.

Run:  python3 tools/diagnostics/kotlin_regex_audit.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_SRC = ROOT / "app" / "src"

# Kotlin Regex("...") or Regex("""...""") with a literal pattern. A trailing
# RegexOption argument is left unmatched on purpose; the lookahead only asserts
# that the string literal ends the pattern.
LITERAL = re.compile(
    r'\bRegex\(\s*(?:"""(.*?)"""|"((?:\\.|[^"\\])*)")\s*(?=[,)])',
    re.S,
)

# (pattern, should_pass). Keeps the detector honest when its own rules change.
SELF_TESTS: list[tuple[str, bool]] = [
    (r"\{([A-Za-z]+)}", False),          # the 3.3.1-pre.17 crash
    (r"\{([A-Za-z]+)\}", True),          # the fix
    (r"\d{8}_\d{6}", True),              # paired quantifiers
    (r"[0-9a-f]{64}", True),
    (r"(?:[0-9a-fA-F]{2}){0,8}", True),
    (r"[{}]", True),                     # braces inside a character class
    (r"\}", True),                       # escaped literal
    (r"foo}", False),                    # lone closing brace
    (r"\{", True),                       # escaped opening brace, no close
]


def decode(value: str, raw: bool) -> str:
    """Turn a Kotlin string literal body into the pattern the engine sees."""
    if raw:
        return value
    escapes = {
        "n": "\n", "t": "\t", "r": "\r", "b": "\b",
        "\\": "\\", '"': '"', "'": "'", "$": "$",
    }
    out: list[str] = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch == "\\" and i + 1 < len(value):
            nxt = value[i + 1]
            # Unknown escapes are illegal Kotlin; keep them verbatim rather than
            # silently dropping the backslash and changing the brace analysis.
            out.append(escapes.get(nxt, "\\" + nxt))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def lone_closing_brace(pattern: str) -> int | None:
    """Index of an unescaped `}` with no matching unescaped `{`, else None."""
    depth = 0
    in_class = False
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "\\":
            i += 2
            continue
        if in_class:
            if ch == "]":
                in_class = False
            i += 1
            continue
        if ch == "[":
            in_class = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            if depth == 0:
                return i
            depth -= 1
        i += 1
    return None


def main() -> int:
    for pattern, should_pass in SELF_TESTS:
        bad = lone_closing_brace(pattern)
        if (bad is None) != should_pass:
            print(f"SELF-TEST FAILED: {pattern!r} (lone_closing_brace={bad})",
                  file=sys.stderr)
            return 2

    findings: list[str] = []
    scanned = 0
    for path in sorted(APP_SRC.rglob("*.kt")):
        text = path.read_text(encoding="utf-8")
        for match in LITERAL.finditer(text):
            raw = match.group(1) is not None
            value = match.group(1) if raw else match.group(2)
            pattern = decode(value, raw)
            scanned += 1
            bad = lone_closing_brace(pattern)
            if bad is not None:
                line = text.count("\n", 0, match.start()) + 1
                findings.append(
                    f"  {path.relative_to(ROOT)}:{line}: unescaped closing brace "
                    f"at pattern index {bad}: {pattern!r}"
                )

    if findings:
        print("kotlin_regex_audit: FAIL - Android ICU would reject these patterns:",
              file=sys.stderr)
        print("\n".join(findings), file=sys.stderr)
        print(r"Escape the closing brace (`\}`) or rewrite the pattern.",
              file=sys.stderr)
        return 1

    print(f"kotlin_regex_audit: OK ({scanned} Regex literals, "
          f"{len(SELF_TESTS)} self-tests)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
