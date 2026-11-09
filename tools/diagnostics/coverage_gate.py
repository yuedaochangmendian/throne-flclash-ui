#!/usr/bin/env python3
"""Fail the Flutter test job when line coverage drops below a floor.

Usage: coverage_gate.py <path/to/lcov.info> --min <percent> [--exclude GLOB ...]
       [--min-dir DIR:PERCENT ...] [--min-file FILE:PERCENT ...] [--report-dirs]

The floor starts deliberately low: it is a regression guard for "the suite
stopped running" and "coverage collapsed", not a target to optimise for. Raise
it in small steps as the suite grows. lcov writes LF/LH per source file, so the
totals are accumulated across all records.

`--min-dir lib/data:80` adds a per-directory floor (paths are the lcov SF
prefixes, i.e. relative to `flutter/`): the newest, most behaviour-dense code
should not hide behind the global average. `--report-dirs` prints every
top-level `lib/<dir>` percentage so the next floor can be set from a measured
number instead of a guess — thresholds are ratchets, and a blind one just
breaks CI on the day it lands.
"""

import argparse
import fnmatch
import sys
from pathlib import Path


def parse_lcov(path: Path) -> dict[str, tuple[int, int]]:
    """`{source file: (lines found, lines hit)}` from an lcov report."""
    files: dict[str, tuple[int, int]] = {}
    current: str | None = None
    found = hit = 0

    def flush() -> None:
        nonlocal current, found, hit
        if current is not None:
            files[current] = (found, hit)
        current, found, hit = None, 0, 0

    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("SF:"):
            flush()
            current = line[3:].strip().replace("\\", "/")
        elif line.startswith("LF:"):
            found += int(line[3:] or 0)
        elif line.startswith("LH:"):
            hit += int(line[3:] or 0)
        elif line.startswith("end_of_record"):
            flush()
    flush()
    return files


def percent(hit: int, found: int) -> float:
    return 100.0 * hit / found if found else 0.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lcov", type=Path)
    parser.add_argument("--min", type=float, default=0.0, help="minimum line coverage in percent")
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="GLOB",
        help="exclude matching lcov SF paths from the overall and per-directory floors",
    )
    parser.add_argument(
        "--min-dir",
        action="append",
        default=[],
        metavar="DIR:PERCENT",
        help="minimum line coverage in percent for every file under DIR (lcov SF prefix, e.g. lib/data:80)",
    )
    parser.add_argument(
        "--min-file",
        action="append",
        default=[],
        metavar="FILE:PERCENT",
        help="minimum line coverage for one exact lcov SF path",
    )
    parser.add_argument(
        "--report-dirs",
        action="store_true",
        help="print line coverage per top-level lib/ directory, for choosing the next floor",
    )
    args = parser.parse_args()

    if not args.lcov.is_file():
        print(f"::error::coverage file not found: {args.lcov}")
        return 1

    files = parse_lcov(args.lcov)
    if args.exclude:
        files = {
            path: value for path, value in files.items()
            if not any(fnmatch.fnmatchcase(path, pattern) for pattern in args.exclude)
        }
    if not files:
        print(f"::error::{args.lcov} has no LF records: did 'flutter test --coverage' run?")
        return 1

    problems = []
    total_found = sum(found for found, _ in files.values())
    total_hit = sum(hit for _, hit in files.values())
    total = percent(total_hit, total_found)
    print(f"line coverage: {total_hit}/{total_found} = {total:.2f}% (floor {args.min:.2f}%)")
    if total < args.min:
        problems.append(f"line coverage {total:.2f}% is below the {args.min:.2f}% floor")

    for spec in args.min_dir:
        try:
            directory, _, raw_floor = spec.rpartition(":")
            floor = float(raw_floor)
        except ValueError:
            problems.append(f"--min-dir {spec!r} is not DIR:PERCENT")
            continue
        found = sum(f for path, (f, _) in files.items() if path.startswith(directory))
        hit = sum(h for path, (_, h) in files.items() if path.startswith(directory))
        if found == 0:
            problems.append(f"--min-dir {directory}: no lcov records under it")
            continue
        covered = percent(hit, found)
        print(f"line coverage [{directory}]: {hit}/{found} = {covered:.2f}% (floor {floor:.2f}%)")
        if covered < floor:
            problems.append(f"{directory} coverage {covered:.2f}% is below the {floor:.2f}% floor")

    for spec in args.min_file:
        try:
            file_path, _, raw_floor = spec.rpartition(":")
            floor = float(raw_floor)
        except ValueError:
            problems.append(f"--min-file {spec!r} is not FILE:PERCENT")
            continue
        if file_path not in files:
            problems.append(f"--min-file {file_path}: no lcov record")
            continue
        found, hit = files[file_path]
        covered = percent(hit, found)
        print(f"line coverage [{file_path}]: {hit}/{found} = {covered:.2f}% (floor {floor:.2f}%)")
        if covered < floor:
            problems.append(f"{file_path} coverage {covered:.2f}% is below the {floor:.2f}% floor")

    if args.report_dirs:
        groups: dict[str, list[int]] = {}
        for path, (found, hit) in files.items():
            parts = path.split("/")
            key = "/".join(parts[:2]) if len(parts) >= 2 and parts[0] == "lib" else path
            bucket = groups.setdefault(key, [0, 0])
            bucket[0] += found
            bucket[1] += hit
        for directory in sorted(groups):
            found, hit = groups[directory]
            print(f"dir coverage [{directory}]: {hit}/{found} = {percent(hit, found):.2f}%")

    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
