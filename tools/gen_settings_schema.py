#!/usr/bin/env python3
"""Generate settings_schema.go from SettingsSchema.kt (ADR 0002, phase 3e).

Parses the Kotlin schema entries and emits a Go table of setting specs so the
two sides cannot drift. Special encodings (signed pairs, inverted flags, alias
rows) go through a hand-written archetype table; the generator verifies every
key found in the source is classified.

Usage:
    python tools/gen_settings_schema.py           # write settings_schema.go
    python tools/gen_settings_schema.py --check   # verify generated matches
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "app/src/main/java/io/flrone/bridge/SettingsSchema.kt"
CONSTANTS = ROOT / "app/src/main/java/io/nekohasekai/sagernet/Constants.kt"
OUTPUT = ROOT / "buildScript/core-patch/core/mobile/settings_schema.go"

# --- regexes (reused from settings_audit.py) ---------------------------------

BRIDGE_KEY = re.compile(
    r'(?:boolEntry|intEntry|textEntry|listEntry)\(\s*"([A-Za-z0-9_]+)"'
    r'|bridgeKey = "([A-Za-z0-9_]+)"'
    r'|Entry\(\s*"([A-Za-z0-9_]+)"'
)
HELPER_TYPE = re.compile(r'(boolEntry|intEntry|textEntry|listEntry)\(\s*"([A-Za-z0-9_]+)"')
APPLY_LEVEL = re.compile(r'Apply\.(None|Reload|AppRestart)')
KEY_CONST = re.compile(r'const val ([A-Z0-9_]+) = "([A-Za-z0-9_]+)"')
STORE_PROP = re.compile(r'DataStore\.([a-zA-Z0-9_]+)')
ALIAS_ROW = re.compile(r'"([A-Za-z0-9_]+)"\s+to\s+"([A-Za-z0-9_]+)"')

# --- hand-written archetype table --------------------------------------------
# Maps bridgeKey to (codecName, rowNames). The codecName must match a codec
# constant in settings_codec.go. Row names are the Room `settings` table keys.
# Keys not in this table use the "direct" codec with camelToSnake(rowName).

ARCHETYPES = {
    # signedPair: two bridge keys share one signed int row (flag = >0).
    "clashApiEnabled":      ("signedPair",   ["core_box_clash_api"]),
    "clashApiPort":         ("signedPair",   ["core_box_clash_api"]),
    "boxApiEnabled":        ("signedPair",   ["core_box_api_port"]),
    "boxApiPort":           ("signedPair",   ["core_box_api_port"]),
    "subAutoUpdateEnabled": ("signedMinutes", ["sub_auto_update"]),
    "subAutoUpdateMinutes": ("signedMinutes", ["sub_auto_update"]),
    "routeAutoUpdateEnabled": ("signedMinutes", ["route_auto_update"]),
    "routeAutoUpdateMinutes": ("signedMinutes", ["route_auto_update"]),
    # invertedBool: bridge key is the negation of the row.
    "allowBypass":          ("invertedBool", ["disable_private_range_bypass"]),
    # addressPair: bool maps to an address string.
    "allowLan":             ("addressPair",  ["inbound_address"]),
    # mappedInt: bool row exposed as 1/2 int.
    "perAppMode":           ("mappedInt",    ["bypassMode"]),
    # newlineList: list stored as newline-separated text.
    "perAppList":           ("newlineList",  ["individual"]),
    "httpProxyBypass":      ("newlineList",  ["httpProxyBypass"]),
    # longAsBool: long row surfaced as bool.
    "startWithoutRuleSets": ("longAsBool",   ["startWithoutRuleSets"]),
    # aliasRow: bridge key maps to a differently-named row.
    "userAgent":            ("aliasRow",     ["user_agent2"]),
    "fakeDns":              ("aliasRow",     ["fakedns"]),
    "warpEndpoint":         ("aliasRow",     ["warp_ep"]),
    "warpMasqueEndpoint":   ("aliasRow",     ["warp_masque_ep"]),
    "perAppEnabled":        ("aliasRow",     ["proxyApps"]),
    "clashApiListenAddr":   ("aliasRow",     ["core_box_clash_listen_addr"]),
    "clashApiSecret":       ("aliasRow",     ["core_box_clash_api_secret"]),
    "boxApiSecret":         ("aliasRow",     ["core_box_api_secret"]),
    # listDefault: list with a non-empty default.
    "notificationActions":  ("listDefault",  ["notificationActions"]),
    # constant: computed, never stored.
    "queryMode":            ("constant",     []),
    "perAppManaged":        ("constant",     []),
    "perAppManagedList":    ("constant",     []),
    "batteryExempt":        ("hostFact",     []),
}

# codec names → Go constant names in settings_codec.go
CODEC_IDS = {
    "direct":        "codecDirect",
    "signedPair":    "codecSignedPair",
    "signedMinutes": "codecSignedMinutes",
    "invertedBool":  "codecInvertedBool",
    "addressPair":   "codecAddressPair",
    "mappedInt":     "codecMappedInt",
    "newlineList":   "codecNewlineList",
    "longAsBool":    "codecLongAsBool",
    "aliasRow":      "codecDirect",       # alias is row-name only; codec is direct
    "listDefault":   "codecListDefault",
    "constant":      "codecConstant",
    "hostFact":      "codecHostFact",
}

# kind name → Go constant
KIND_IDS = {
    "boolEntry": "kindBool",
    "intEntry":  "kindInt",
    "textEntry": "kindText",
    "listEntry": "kindList",
    "Entry":     "kindText",  # default for raw Entry() — refined below
}


def camel_to_snake(name: str) -> str:
    out = []
    for c in name:
        if c.isupper():
            out.append("_")
            out.append(c.lower())
        else:
            out.append(c)
    return "".join(out)


def parse_constants() -> dict[str, str]:
    """Map ConstantName → row_name from Constants.kt."""
    text = CONSTANTS.read_text(encoding="utf-8")
    return {m.group(1): m.group(2) for m in KEY_CONST.finditer(text)}


def parse_entries(schema_text: str) -> list[dict]:
    """Extract each schema entry's bridgeKey, helper type, apply level, autoRestartable."""
    entries = []
    # Split on entry boundaries: each entry starts with a helper call or Entry(.
    # We scan for bridgeKey occurrences and capture surrounding context.
    for m in BRIDGE_KEY.finditer(schema_text):
        key = m.group(1) or m.group(2) or m.group(3)
        # Find the enclosing entry block (from ~200 chars before to ~400 chars after).
        start = max(0, m.start() - 300)
        end = min(len(schema_text), m.end() + 500)
        block = schema_text[start:end]

        # Helper type.
        helper = "Entry"
        hm = HELPER_TYPE.search(schema_text[max(0, m.start()-50):m.end()+10])
        if hm and hm.group(2) == key:
            helper = hm.group(1)

        # Apply level: find Apply.X in the entry's own argument list.
        # The entry starts at the helper/Entry call and ends at the matching close.
        apply = "None"
        # Look at text from the helper call to the next helper call or 400 chars.
        entry_start = m.start()
        # Find the end: next occurrence of a helper call or Entry( after this one.
        next_entry = BRIDGE_KEY.search(schema_text, m.end() + 5)
        entry_end = next_entry.start() if next_entry else min(len(schema_text), m.end() + 600)
        entry_text = schema_text[entry_start:entry_end]
        apply_matches = list(APPLY_LEVEL.finditer(entry_text))
        if apply_matches:
            apply = apply_matches[0].group(1)

        # autoRestartable: only explicit `autoRestartable = true` or the 3-arg boolEntry
        # pattern `boolEntry("key", Apply.X, true,`.
        auto_restart = "false"
        if "autoRestartable = true" in entry_text:
            auto_restart = "true"
        elif re.search(r'boolEntry\(\s*"[^"]+",\s*Apply\.\w+,\s*true,', entry_text):
            auto_restart = "true"

        entries.append({
            "key": key,
            "helper": helper,
            "apply": apply,
            "autoRestartable": auto_restart,
        })

    # Deduplicate by key (bridgeKey regex can match multiple times).
    seen = {}
    for e in entries:
        seen[e["key"]] = e
    return list(seen.values())


def row_name_for(key: str, constants: dict[str, str]) -> str:
    """Determine the Room row name for a bridge key."""
    # Check if the key is a DataStore property name that maps to a constant.
    # Try camelToSnake first.
    snake = camel_to_snake(key)
    # Check if any constant value matches the snake form.
    for _const_name, row_name in constants.items():
        if row_name == snake:
            return row_name
    # Check direct key match.
    if key in constants.values():
        return key
    # Fallback: camelToSnake.
    return snake


def generate(entries: list[dict], constants: dict[str, str]) -> str:
    lines = [
        "// Code generated by tools/gen_settings_schema.py. DO NOT EDIT.",
        "//",
        "// The settings schema mirrored from SettingsSchema.kt (ADR 0002, phase 3e).",
        "// Each spec maps a bridge key to its Room row name(s), type, apply level",
        "// and codec. The codec handles split/computed encodings (signed pairs,",
        "// inverted flags, alias rows, etc.).",
        "package mobile",
        "",
        "type settingKind uint8",
        "",
        "const (",
        "\tkindBool settingKind = iota",
        "\tkindInt",
        "\tkindText",
        "\tkindList",
        ")",
        "",
        "type settingCodec uint8",
        "",
        "const (",
        "\tcodecDirect settingCodec = iota",
        "\tcodecSignedPair",
        "\tcodecSignedMinutes",
        "\tcodecInvertedBool",
        "\tcodecAddressPair",
        "\tcodecMappedInt",
        "\tcodecNewlineList",
        "\tcodecLongAsBool",
        "\tcodecListDefault",
        "\tcodecConstant",
        "\tcodecHostFact",
        ")",
        "",
        "type settingSpec struct {",
        "\tbridgeKey      string",
        "\tkind           settingKind",
        "\tapply          int // 0=None, 1=Reload, 2=AppRestart",
        "\tautoRestartable bool",
        "\tcodec          settingCodec",
        "\trowKeys        []string",
        "}",
        "",
        "var settingSpecs = []settingSpec{",
    ]

    for e in sorted(entries, key=lambda x: x["key"]):
        key = e["key"]
        helper = e["helper"]
        kind = KIND_IDS.get(helper, "kindText")

        # Refine kind for raw Entry() based on archetype.
        if helper == "Entry":
            arch = ARCHETYPES.get(key)
            if arch:
                if arch[0] in ("invertedBool", "addressPair", "longAsBool", "hostFact"):
                    kind = "kindBool"
                elif arch[0] == "mappedInt":
                    kind = "kindInt"
                elif arch[0] == "newlineList":
                    kind = "kindList"
                elif arch[0] == "constant":
                    if key == "perAppManagedList":
                        kind = "kindList"
                    elif key == "perAppManaged":
                        kind = "kindBool"
                    else:
                        kind = "kindText"
                elif arch[0] == "signedPair":
                    kind = "kindBool" if key.endswith("Enabled") else "kindInt"
                else:
                    kind = "kindText"
            else:
                kind = "kindText"

        # Fix kind for helper-based entries with special codecs.
        arch = ARCHETYPES.get(key, ("direct", []))
        if helper != "Entry":
            if arch[0] == "signedPair":
                kind = "kindBool" if key.endswith("Enabled") else "kindInt"
            elif arch[0] == "signedMinutes":
                kind = "kindBool" if key.endswith("Enabled") else "kindInt"
            elif arch[0] == "addressPair":
                kind = "kindBool"
            elif arch[0] == "longAsBool":
                kind = "kindBool"

        apply_num = {"None": 0, "Reload": 1, "AppRestart": 2}[e["apply"]]
        auto = "true" if e["autoRestartable"] == "true" else "false"

        arch = ARCHETYPES.get(key, ("direct", []))
        codec_name = CODEC_IDS.get(arch[0], "codecDirect")

        if arch[1]:
            rows = ", ".join(f'"{r}"' for r in arch[1])
            rows_go = f"[]string{{{rows}}}"
        else:
            row = row_name_for(key, constants)
            rows_go = f'[]string{{"{row}"}}'

        lines.append(
            f'\t{{bridgeKey: "{key}", kind: {kind}, apply: {apply_num}, '
            f'autoRestartable: {auto}, codec: {codec_name}, rowKeys: {rows_go}}},'
        )

    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    if not SCHEMA.exists():
        print(f"error: {SCHEMA} not found", file=sys.stderr)
        return 1

    schema_text = SCHEMA.read_text(encoding="utf-8")
    constants = parse_constants()
    entries = parse_entries(schema_text)

    # Verify all entries are classified (or use direct codec).
    unclassified = [e["key"] for e in entries if e["key"] not in ARCHETYPES]
    # Direct is fine — just informational.
    if unclassified:
        print(f"info: {len(unclassified)} keys use direct codec", file=sys.stderr)

    output = generate(entries, constants)

    if "--check" in sys.argv:
        if not OUTPUT.exists():
            print(f"FAIL: {OUTPUT} does not exist", file=sys.stderr)
            return 1
        existing = OUTPUT.read_text(encoding="utf-8")
        if existing != output:
            print(f"FAIL: {OUTPUT} is stale; run gen_settings_schema.py", file=sys.stderr)
            return 1
        print(f"OK: {OUTPUT.name} matches source ({len(entries)} keys)")
        return 0

    OUTPUT.write_text(output, encoding="utf-8")
    print(f"wrote {OUTPUT.name} ({len(entries)} keys)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
