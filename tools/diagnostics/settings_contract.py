#!/usr/bin/env python3
"""Verify settings_schema.go matches SettingsSchema.kt (ADR 0002, phase 3e).

Runs the generator in --check mode and additionally diffs the key set against
the Kotlin source so a schema edit that forgets regeneration fails loudly.

Usage:
    python tools/diagnostics/settings_contract.py
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
GENERATOR = ROOT / "tools" / "gen_settings_schema.py"
SCHEMA_KT = ROOT / "app/src/main/java/io/flrone/bridge/SettingsSchema.kt"
SCHEMA_GO = ROOT / "buildScript/core-patch/core/mobile/settings_schema.go"

BRIDGE_KEY = re.compile(
    r'(?:boolEntry|intEntry|textEntry|listEntry)\(\s*"([A-Za-z0-9_]+)"'
    r'|bridgeKey = "([A-Za-z0-9_]+)"'
    r'|Entry\(\s*"([A-Za-z0-9_]+)"'
)
GO_KEY = re.compile(r'bridgeKey: "([A-Za-z0-9_]+)"')


def main() -> int:
    problems = []

    # 1. Run the generator's --check mode.
    result = subprocess.run(
        [sys.executable, str(GENERATOR), "--check"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        problems.append(f"generator --check failed: {result.stderr.strip()}")

    # 2. Verify the key sets match.
    if SCHEMA_KT.exists() and SCHEMA_GO.exists():
        kt_keys = set()
        for m in BRIDGE_KEY.finditer(SCHEMA_KT.read_text(encoding="utf-8")):
            key = m.group(1) or m.group(2) or m.group(3)
            if key:
                kt_keys.add(key)

        go_keys = set(GO_KEY.findall(SCHEMA_GO.read_text(encoding="utf-8")))

        for key in sorted(kt_keys - go_keys):
            problems.append(f"key {key!r} in SettingsSchema.kt but not in settings_schema.go")
        for key in sorted(go_keys - kt_keys):
            problems.append(f"key {key!r} in settings_schema.go but not in SettingsSchema.kt")
    else:
        problems.append(f"missing file: schema_kt={SCHEMA_KT.exists()} schema_go={SCHEMA_GO.exists()}")

    if problems:
        for p in problems:
            print(f"::error::{p}")
        return 1

    print(f"settings contract OK: {len(go_keys) if SCHEMA_GO.exists() else '?'} keys agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
