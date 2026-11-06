#!/usr/bin/env python3
"""Fail the Flutter test job when line coverage drops below a floor.

Usage: coverage_gate.py <path/to/lcov.info> --min <percent>

The floor starts deliberately low: it is a regression guard for "the suite
stopped running" and "coverage collapsed", not a target to optimise for. Raise
it in small steps as the suite grows. lcov writes LF/LH per source file, so the
totals are accumulated across all records.
"""

import argparse
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lcov", type=Path)
    parser.add_argument("--min", type=float, default=0.0, help="minimum line coverage in percent")
    args = parser.parse_args()

    if not args.lcov.is_file():
        print(f"::error::coverage file not found: {args.lcov}")
        return 1

    found = hit = 0
    for line in args.lcov.read_text(errors="replace").splitlines():
        if line.startswith("LF:"):
            found += int(line[3:] or 0)
        elif line.startswith("LH:"):
            hit += int(line[3:] or 0)

    if found == 0:
        print(f"::error::{args.lcov} has no LF records: did 'flutter test --coverage' run?")
        return 1

    percent = 100.0 * hit / found
    print(f"line coverage: {hit}/{found} = {percent:.2f}% (floor {args.min:.2f}%)")
    if percent < args.min:
        print(f"::error::line coverage {percent:.2f}% is below the {args.min:.2f}% floor")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
