"""Inert: the three-way settings-surface audit this script performed no longer has a subject.

What it used to do
------------------
It diffed three columns of the Throne settings surface:

  1. store keys  — `SettingsRegistry.kt` plus the `Key` object in `Constants.kt`
  2. bridge keys — `app/src/main/java/io/throne/bbox/bridge/SettingsSchema.kt`,
                   the B-box bridge's typed schema over those rows, plus its
                   RESET_ROW_ALIASES map
  3. UI keys     — the `Setting*(<title>, 'key')` controls on
                   `flutter/lib/pages/throne.dart`, and the keys each page's
                   `restoreDefaultsAction` reset

A store key was covered when some schema entry was its row; a bridge key was
covered when a `Setting*` control edited it; a UI key was covered when a schema
entry backed it. Uncovered keys had to be declared in one of three hand-maintained
books (runtime state, shell-owned, restore-only), so the diff only ever named
actionable work.

Why it cannot run any more
--------------------------
Two of the three columns were deleted by the FlClash UI migration:

  * `SettingsSchema.kt` is gone (with 18 other `Bbox*.kt` bridge classes), and
  * `flutter/lib/pages/throne.dart` and the whole `Setting*` control family are
    gone — the FlClash settings pages edit their own Riverpod state
    (`AppSettingProps`, `patchClashConfigProvider`) and never address a Throne
    store row across the channel.

`SettingsRegistry.kt` and `Constants.kt` survived, so a "diff" of the remaining
column against nothing would name every store key as a gap — thousands of lines of
noise nobody could act on, which is the opposite of what a gate is for.

What this script does instead
-----------------------------
It stays in the tree as the record of a deleted contract and keeps one real
invariant: if the audited surface ever comes back (a new `SettingsSchema.kt`, or a
`SettingToggle`/`SettingChoice`/`SettingText`/`SettingNumber`/`SettingLines`/
`SettingDnsServer`/`SettingJson` control under `flutter/lib`), it fails and asks
for the audit to be rebuilt against the new code. A no-op that would also pass a
re-introduced bridge is the one thing a retired gate must not be.

Run from the repository root:
    python3 tools/diagnostics/settings_audit.py [--summary]

Exit 0 while the audited surface is absent; 1 if it is back and the audit is still
inert.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = REPO_ROOT / "app/src/main/java/io/throne/bbox/bridge/SettingsSchema.kt"
FLUTTER_LIB = REPO_ROOT / "flutter/lib"

# The control family the old UI used. Any of these under flutter/lib means the
# bridge-keyed settings surface exists again.
CONTROL_RE = re.compile(
    r"\bSetting(?:Choice|Toggle|Text|Number|Lines|DnsServer|Json)\s*[(<]"
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--summary", action="store_true",
                        help="accepted for compatibility; this audit has no columns to count")
    parser.parse_args()

    revived: list[str] = []
    if SCHEMA.exists():
        revived.append(str(SCHEMA.relative_to(REPO_ROOT)))

    controls = 0
    for path in FLUTTER_LIB.rglob("*.dart"):
        controls += len(CONTROL_RE.findall(path.read_text(encoding="utf-8")))
    if controls:
        revived.append(f"{controls} Setting* control(s) under flutter/lib")

    if revived:
        print("FAIL — the bridge-keyed settings surface this audit retired is back:")
        for item in revived:
            print(f"  - {item}")
        print(
            "\nRebuild the three-way diff (store keys <-> bridge keys <-> Setting* keys)"
            " against the new code before merging, then delete this message."
        )
        return 1

    print(
        "retired: SettingsSchema.kt and the Setting* control family are both gone with the "
        "FlClash UI migration, so the store-key/bridge-key/UI-key diff has no columns left. "
        "Nothing to audit; this script only watches for the surface coming back."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
