"""i18n coverage diagnostic for Flrone string resources.

Read-only checks against app/src/main/res:
  - missing / extra entries per locale (strings, plurals, arrays)
  - non-translatable ("translatable=\"false\"") entries leaking into locales
  - format placeholder multiset mismatches vs the base entry
  - missing CLDR plural quantity categories per locale
  - duplicate names and XML parse errors

Run from the repository root:
    uv run tools/diagnostics/i18n_coverage.py [--lang values-it] [--summary]

Exit code 0 when every checked locale is clean, 1 when any issue is found.

## The ratchet

Nineteen locales have gaps (885 of them at the time this was added), so failing
on any issue would block every unrelated change and the gate would be disabled
within a week. Counting the gaps is not enough either: translating one string
while adding another leaves the count identical, which is exactly the drift a
gate exists to stop.

`--ratchet` therefore compares the *set* of issues against
`i18n_baseline.txt`: an issue that is not in the baseline fails the build, and
an issue that was in the baseline but is gone is reported as progress. Adding
translations is always allowed; only new gaps are refused.
`--update-baseline` rewrites the file after a gap is fixed, so the ratchet
tightens and can never loosen by accident.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RES_DIR = REPO_ROOT / "app" / "src" / "main" / "res"
DEFAULT_BASELINE = Path(__file__).resolve().parent / "i18n_baseline.txt"

# CLDR plural quantities each locale MUST provide (superset allowed).
REQUIRED_QUANTITIES: dict[str, set[str]] = {
    "ar": {"zero", "one", "two", "few", "many", "other"},
    "be": {"one", "few", "many", "other"},
    "ru": {"one", "few", "many", "other"},
    "uk": {"one", "few", "many", "other"},
    "ja": {"other"},
    "zh": {"other"},
    "ko": {"other"},
}
DEFAULT_QUANTITIES = {"one", "other"}

PLACEHOLDER_RE = re.compile(r"%(?:(\d+)\$)?(?:\.\d+)?([a-zA-Z])")


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def is_translatable(el: ET.Element) -> bool:
    return el.get("translatable", "true").lower() != "false"


def text_of(el: ET.Element) -> str:
    return "".join(el.itertext())


def placeholders(text: str) -> Counter[str]:
    text = text.replace("%%", "")
    return Counter(m.group(0) for m in PLACEHOLDER_RE.finditer(text))


def locale_language(dir_name: str) -> str:
    # values-zh-rCN -> zh, values-nb-rNO -> nb, values-pt-rBR -> pt
    return dir_name[len("values-"):].split("-")[0]


def parse_xml(path: Path, issues: list[str]) -> ET.Element | None:
    if not path.exists():
        return None
    try:
        return ET.parse(path).getroot()
    except ET.ParseError as exc:
        issues.append(f"{path.parent.name}/{path.name}: XML parse error: {exc}")
        return None


def collect_entries(root: ET.Element | None) -> tuple[dict[str, ET.Element], dict[str, ET.Element], dict[str, ET.Element]]:
    strings: dict[str, ET.Element] = {}
    plurals: dict[str, ET.Element] = {}
    arrays: dict[str, ET.Element] = {}
    if root is None:
        return strings, plurals, arrays
    for el in root:
        name = el.get("name")
        if not name:
            continue
        kind = local_name(el.tag)
        if kind == "string":
            strings[name] = el
        elif kind == "plurals":
            plurals[name] = el
        elif kind == "string-array":
            arrays[name] = el
    return strings, plurals, arrays


def duplicates(root: ET.Element | None) -> list[str]:
    if root is None:
        return []
    seen: Counter[str] = Counter()
    for el in root:
        name = el.get("name")
        if name:
            seen[name] += 1
    return [f"duplicate name '{n}' x{c}" for n, c in seen.items() if c > 1]


def plural_items(el: ET.Element) -> dict[str, str]:
    return {
        item.get("quantity", ""): text_of(item)
        for item in el
        if local_name(item.tag) == "item"
    }


def array_items(el: ET.Element) -> list[str]:
    return [text_of(item) for item in el if local_name(item.tag) == "item"]


def check_placeholders(
    label: str, base_el: ET.Element, loc_el: ET.Element, issues: list[str]
) -> None:
    if base_el.get("formatted", "true").lower() == "false":
        return
    base_tokens = placeholders(text_of(base_el))
    loc_tokens = placeholders(text_of(loc_el))
    if base_tokens != loc_tokens:
        issues.append(
            f"{label}: placeholder mismatch base={sorted(base_tokens.elements())} "
            f"locale={sorted(loc_tokens.elements())}"
        )


def check_locale(
    res_dir: Path,
    locale_dir: Path,
    base_strings: dict[str, ET.Element],
    base_plurals: dict[str, ET.Element],
    base_arrays: dict[str, ET.Element],
    base_string_names: set[str],
    base_plural_names: set[str],
    base_array_names: set[str],
    nontranslatable_strings: set[str],
    nontranslatable_arrays: set[str],
) -> list[str]:
    issues: list[str] = []
    lang = locale_language(locale_dir.name)
    required_quantities = REQUIRED_QUANTITIES.get(lang, DEFAULT_QUANTITIES)

    strings_root = parse_xml(locale_dir / "strings.xml", issues)
    arrays_root = parse_xml(locale_dir / "arrays.xml", issues)
    issues.extend(f"{locale_dir.name}: {d}" for d in duplicates(strings_root))
    issues.extend(f"{locale_dir.name}: {d}" for d in duplicates(arrays_root))

    loc_strings, loc_plurals, _ = collect_entries(strings_root)
    _, _, loc_arrays = collect_entries(arrays_root)
    present = set(loc_strings) | set(loc_plurals)

    for name in sorted(set(loc_strings) | set(loc_plurals)):
        if name in nontranslatable_strings:
            issues.append(f"{locale_dir.name}: non-translatable leak: {name}")
        elif name not in base_string_names | base_plural_names:
            issues.append(f"{locale_dir.name}: extra entry not in base: {name}")
    for name in sorted(set(loc_arrays)):
        if name in nontranslatable_arrays:
            issues.append(f"{locale_dir.name}: non-translatable leak: {name}")
        elif name not in base_array_names:
            issues.append(f"{locale_dir.name}: extra entry not in base: {name}")

    for name in sorted(base_string_names - present):
        issues.append(f"{locale_dir.name}: missing string: {name}")
    for name in sorted(base_plural_names - set(loc_plurals)):
        issues.append(f"{locale_dir.name}: missing plurals: {name}")
    for name in sorted(base_array_names - set(loc_arrays)):
        issues.append(f"{locale_dir.name}: missing string-array: {name}")

    for name, el in loc_strings.items():
        if name in base_strings:
            check_placeholders(f"{locale_dir.name}/{name}", base_strings[name], el, issues)

    for name, el in loc_plurals.items():
        if name not in base_plurals:
            continue
        base_items = plural_items(base_plurals[name])
        loc_items = plural_items(el)
        missing_q = required_quantities - set(loc_items)
        if missing_q:
            issues.append(
                f"{locale_dir.name}/{name}: missing plural quantities: {sorted(missing_q)}"
            )
        fallback = base_items.get("other") or next(iter(base_items.values()), "")
        for quantity, text in loc_items.items():
            base_text = base_items.get(quantity, fallback)
            if placeholders(base_text) != placeholders(text):
                issues.append(
                    f"{locale_dir.name}/{name}[{quantity}]: placeholder mismatch "
                    f"base={sorted(placeholders(base_text).elements())} "
                    f"locale={sorted(placeholders(text).elements())}"
                )

    for name, el in loc_arrays.items():
        if name not in base_arrays:
            continue
        base_items = array_items(base_arrays[name])
        loc_items = array_items(el)
        if len(base_items) != len(loc_items):
            issues.append(
                f"{locale_dir.name}/{name}: item count mismatch "
                f"base={len(base_items)} locale={len(loc_items)}"
            )
            continue
        for i, (b, l) in enumerate(zip(base_items, loc_items)):
            if placeholders(b) != placeholders(l):
                issues.append(
                    f"{locale_dir.name}/{name}[{i}]: placeholder mismatch "
                    f"base={sorted(placeholders(b).elements())} "
                    f"locale={sorted(placeholders(l).elements())}"
                )

    return issues


def read_baseline(path: Path) -> set[str] | None:
    """The accepted issues, or None when there is no baseline yet."""
    if not path.exists():
        return None
    return {
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def write_baseline(path: Path, issues: set[str]) -> None:
    header = (
        "# Accepted i18n gaps, one per line (tools/diagnostics/i18n_coverage.py --ratchet).\n"
        "# This file is a ceiling, not a target: translating strings removes lines,\n"
        "# adding an untranslated string adds one and fails CI until it is translated\n"
        "# or this file is regenerated with --update-baseline (a deliberate act).\n"
    )
    path.write_text(header + "".join(f"{issue}\n" for issue in sorted(issues)),
                    encoding="utf-8", newline="\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--res-dir", type=Path, default=DEFAULT_RES_DIR,
                        help="resource directory (default: app/src/main/res)")
    parser.add_argument("--lang", help="only check one locale dir, e.g. values-it")
    parser.add_argument("--summary", action="store_true",
                        help="print per-locale counts only, no item details")
    parser.add_argument("--ratchet", action="store_true",
                        help="fail only on gaps the baseline does not already accept")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE,
                        help="baseline file used by --ratchet")
    parser.add_argument("--update-baseline", action="store_true",
                        help="rewrite the baseline from the current gaps, then pass")
    args = parser.parse_args()

    res_dir: Path = args.res_dir
    base_issues: list[str] = []
    base_strings_root = parse_xml(res_dir / "values" / "strings.xml", base_issues)
    base_arrays_root = parse_xml(res_dir / "values" / "arrays.xml", base_issues)
    if base_issues or base_strings_root is None or base_arrays_root is None:
        for line in base_issues:
            print(f"BASE: {line}")
        print("FATAL: cannot parse base resources")
        return 1

    b_strings, b_plurals, _ = collect_entries(base_strings_root)
    _, _, b_arrays = collect_entries(base_arrays_root)

    base_string_names = {n for n, el in b_strings.items() if is_translatable(el)}
    base_plural_names = {n for n, el in b_plurals.items() if is_translatable(el)}
    base_array_names = {n for n, el in b_arrays.items() if is_translatable(el)}
    nontranslatable_strings = {
        n for n, el in list(b_strings.items()) + list(b_plurals.items())
        if not is_translatable(el)
    }
    nontranslatable_arrays = {n for n, el in b_arrays.items() if not is_translatable(el)}

    locale_dirs = sorted(
        d for d in res_dir.glob("values-*")
        if d.is_dir() and (d / "strings.xml").exists()
    )
    if args.lang:
        locale_dirs = [d for d in locale_dirs if d.name == args.lang]
        if not locale_dirs:
            print(f"FATAL: no locale dir matching {args.lang}")
            return 1

    total_issues = 0
    all_issues: set[str] = set()
    for locale_dir in locale_dirs:
        issues = check_locale(
            res_dir, locale_dir,
            b_strings, b_plurals, b_arrays,
            base_string_names, base_plural_names, base_array_names,
            nontranslatable_strings, nontranslatable_arrays,
        )
        total_issues += len(issues)
        all_issues.update(issues)
        counts = Counter(
            "missing" if ": missing" in i else
            "extra" if (": extra" in i or "leak" in i) else
            "placeholder" if "placeholder" in i else
            "plural_qty" if "plural quantities" in i else
            "structure" if "mismatch base=" not in i and "count mismatch" in i else
            "other"
            for i in issues
        )
        print(
            f"{locale_dir.name}: missing={counts['missing']} extra={counts['extra']} "
            f"placeholder={counts['placeholder']} plural_qty={counts['plural_qty']} "
            f"other={counts['other']} total={len(issues)}"
        )
        if not args.summary and not args.ratchet:
            for line in issues:
                print(f"  - {line}")

    print(f"checked {len(locale_dirs)} locale(s), {total_issues} issue(s)")

    if args.update_baseline:
        write_baseline(args.baseline, all_issues)
        print(f"baseline updated: {args.baseline.name} now lists {len(all_issues)} gap(s)")
        return 0

    if not args.ratchet:
        return 1 if total_issues else 0

    # The ratchet: a gap the baseline never accepted is a regression, even when
    # another gap was fixed in the same change and the total did not move.
    baseline = read_baseline(args.baseline)
    if baseline is None:
        print(f"FATAL: {args.baseline} is missing; run with --update-baseline once")
        return 1
    new_gaps = sorted(all_issues - baseline)
    closed = sorted(baseline - all_issues)
    for gap in new_gaps:
        print(f"NEW: {gap}")
    if closed:
        print(f"closed {len(closed)} accepted gap(s) — run --update-baseline to tighten the ratchet")
        for gap in closed[:10]:
            print(f"  closed: {gap}")
    if new_gaps:
        print(f"FAIL: {len(new_gaps)} new i18n gap(s) beyond the {len(baseline)} accepted")
        print("      translate them, or accept them deliberately with --update-baseline")
        return 1
    print(f"i18n ratchet OK: {len(all_issues)} gap(s), all within the accepted {len(baseline)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())