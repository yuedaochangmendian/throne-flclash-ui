#!/usr/bin/env python3
# Copyright 2026 Flrone. All rights reserved.
"""Drift detector between the vendored Prism UI copy and upstream chen08209/prism_ui.

The Flrone Flutter UI under ``flutter/lib/ui`` vendors a fork of
``chen08209/prism_ui``. This tool measures how far the vendored copy has
drifted from a pinned upstream baseline so we can decide when a sync/merge is
warranted, and it keeps that decision auditable.

Two artifacts live next to this script:

* ``prism_upstream.lock.json``      — pinned baseline metadata (repo, ref, commit).
* ``prism_upstream.manifest.json``  — normalized ``{relative_path: sha256}`` of the
  pinned upstream checkout. Committed so CI can run fully offline and
  deterministically; regenerate it with ``snapshot``.

Modes
-----
``snapshot``  Build the baseline manifest from a fresh upstream checkout and write
              it (plus the lock file) next to this script. Requires ``--upstream``.
``check``     (default) Compare the current vendored copy against the committed
              baseline manifest and print a report. Exits non-zero only when
              ``--fail-on`` names a category that is non-empty or ``--max-drift`` is
              exceeded. By default it is informational (exit 0).

Normalization
-------------
Both sides are canonicalized so the *intentional* package rename
(``package:prism_ui`` -> ``package:flrone/ui``) and line-ending differences do
not register as drift:

* both ``package:prism_ui/`` and ``package:flrone/ui/`` become a single sentinel;
* CRLF and bare CR are normalized to LF;
* a single trailing newline is enforced (EOF whitespace is ignored).

Run ``python3 tools/diagnostics/prism_drift.py --help`` for all options.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Dict, Tuple

# --- paths -----------------------------------------------------------------
HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
LOCK_PATH = HERE / "prism_upstream.lock.json"
MANIFEST_PATH = HERE / "prism_upstream.manifest.json"

DEFAULT_LOCAL = REPO_ROOT / "flutter" / "lib" / "ui"
DEFAULT_UPSTREAM_REPO = "https://github.com/chen08209/prism_ui.git"

# Package prefixes that mean the same thing on each side of the fork.
_PACKAGE_PREFIXES = ("package:prism_ui/", "package:flrone/ui/")
_SENTINEL = "package:__PRISM_UI__/"


# --- normalization ---------------------------------------------------------
def normalize(text: str) -> str:
    """Canonicalize Dart source so the fork rename + line endings are ignored."""
    for prefix in _PACKAGE_PREFIXES:
        text = text.replace(prefix, _SENTINEL)
    # Normalize line endings to LF.
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # Collapse trailing blank lines and enforce exactly one trailing newline.
    lines = text.split("\n")
    while lines and lines[-1].strip() == "":
        lines.pop()
    return "\n".join(lines) + "\n"


def file_hash(path: Path) -> str:
    return hashlib.sha256(normalize(path.read_text(encoding="utf-8")).encode("utf-8")).hexdigest()


def collect(root: Path) -> Dict[str, str]:
    """Return ``{relative_posix_path: normalized_sha256}`` for every .dart file."""
    out: Dict[str, str] = {}
    for p in sorted(root.rglob("*.dart")):
        if ".dart_tool" in p.parts or p.name.startswith("."):
            continue
        rel = p.relative_to(root).as_posix()
        out[rel] = file_hash(p)
    return out


# --- manifest ---------------------------------------------------------------
def detect_commit(upstream_dir: Path) -> str:
    """Best-effort: resolve the upstream checkout's HEAD commit via git."""
    cur = upstream_dir.resolve()
    for _ in range(6):
        if (cur / ".git").exists():
            try:
                import subprocess
                out = subprocess.run(
                    ["git", "-C", str(cur), "rev-parse", "HEAD"],
                    capture_output=True, text=True, check=True,
                )
                return out.stdout.strip()
            except Exception:
                return ""
        if str(cur) == cur.parent:
            break
        cur = cur.parent
    return ""


def write_manifest(upstream_dir: Path, commit: str, ref: str) -> Dict[str, str]:
    manifest = collect(upstream_dir)
    payload = {
        "generated_by": "tools/diagnostics/prism_drift.py snapshot",
        "repo": DEFAULT_UPSTREAM_REPO,
        "ref": ref,
        "commit": commit,
        "file_count": len(manifest),
        "files": manifest,
    }
    MANIFEST_PATH.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    LOCK_PATH.write_text(
        json.dumps(
            {
                "repo": DEFAULT_UPSTREAM_REPO,
                "ref": ref,
                "commit": commit,
                "note": (
                    "Pinned upstream baseline for Prism UI drift detection. "
                    "Regenerate the manifest with `prism_drift.py snapshot --upstream <checkout>` "
                    "after verifying the commit below is what we intend to track."
                ),
                "manifest": "prism_upstream.manifest.json",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return manifest


# --- comparison -------------------------------------------------------------
def compare(baseline: Dict[str, str], local: Dict[str, str]) -> Dict[str, list]:
    base_keys = set(baseline)
    local_keys = set(local)
    identical, diverged, added, removed = [], [], [], []
    for k in sorted(base_keys & local_keys):
        (identical if baseline[k] == local[k] else diverged).append(k)
    for k in sorted(local_keys - base_keys):
        added.append(k)
    for k in sorted(base_keys - local_keys):
        removed.append(k)
    return {"identical": identical, "diverged": diverged, "added": added, "removed": removed}


def render_report(meta: dict, res: dict, local_root: Path) -> str:
    lines = []
    lines.append("Prism UI drift report")
    lines.append("=" * 60)
    lines.append(f"baseline ref : {meta.get('ref')} @ {meta.get('commit')}")
    lines.append(f"baseline files: {meta.get('file_count')}")
    lines.append(f"local root   : {local_root}")
    lines.append("")
    lines.append(f"  identical : {len(res['identical'])}")
    lines.append(f"  diverged  : {len(res['diverged'])}")
    lines.append(f"  added     : {len(res['added'])}   (local-only, not in upstream)")
    lines.append(f"  removed   : {len(res['removed'])}   (upstream-only, dropped locally)")
    lines.append("")
    if res["diverged"]:
        lines.append("Diverged files (present in both, content differs after normalization):")
        for f in res["diverged"]:
            lines.append(f"  - {f}")
        lines.append("")
    if res["added"]:
        lines.append("Added locally (vendored extensions / forks not in upstream):")
        for f in res["added"]:
            lines.append(f"  + {f}")
        lines.append("")
    if res["removed"]:
        lines.append("Removed locally (upstream files no longer vendored):")
        for f in res["removed"]:
            lines.append(f"  x {f}")
        lines.append("")
    if not any([res["diverged"], res["added"], res["removed"]]):
        lines.append("No drift: the vendored copy matches the pinned baseline exactly.")
    return "\n".join(lines)


# --- CLI --------------------------------------------------------------------
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Prism UI drift detector")
    ap.add_argument("mode", nargs="?", choices=["check", "snapshot", "report"], default="check",
                    help="check (default), snapshot, or report (=check)")
    ap.add_argument("--upstream", type=Path, help="upstream lib/ directory (snapshot mode)")
    ap.add_argument("--local", type=Path, default=DEFAULT_LOCAL, help="vendored ui directory (check mode)")
    ap.add_argument("--ref", default="main", help="upstream ref name recorded in the lock file")
    ap.add_argument("--commit", default="", help="upstream commit hash recorded in the lock file")
    ap.add_argument("--json", type=Path, help="write the comparison result as JSON to this path")
    ap.add_argument("--fail-on", choices=["diverged", "added", "removed", "any"],
                    help="exit non-zero if the named category is non-empty")
    ap.add_argument("--max-drift", type=int, default=-1,
                    help="exit non-zero if diverged+removed+added exceeds this (default: never)")
    args = ap.parse_args(argv)

    if args.mode == "snapshot":
        if not args.upstream or not args.upstream.is_dir():
            ap.error("--upstream <dir> is required for snapshot and must exist")
        commit = args.commit or detect_commit(args.upstream)
        if not commit:
            commit = "unknown"
            print("WARNING: could not resolve upstream commit; pass --commit explicitly.", file=sys.stderr)
        manifest = write_manifest(args.upstream, commit, args.ref)
        print(f"Wrote baseline manifest: {len(manifest)} files -> {MANIFEST_PATH}")
        print(f"Wrote lock file -> {LOCK_PATH}")
        return 0

    if not MANIFEST_PATH.is_file():
        print(f"ERROR: baseline manifest missing: {MANIFEST_PATH}\n"
              f"Run `prism_drift.py snapshot --upstream <prism_ui/lib>` first.", file=sys.stderr)
        return 2
    meta = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    baseline = meta.get("files", {})
    local = collect(args.local)
    res = compare(baseline, local)
    print(render_report(meta, res, args.local))
    if args.json:
        args.json.write_text(json.dumps({"meta": meta, "result": res}, indent=2) + "\n", encoding="utf-8")
        print(f"\nJSON written -> {args.json}")

    failed = False
    if args.fail_on == "any" and any([res["diverged"], res["added"], res["removed"]]):
        failed = True
    elif args.fail_on == "diverged" and res["diverged"]:
        failed = True
    elif args.fail_on == "added" and res["added"]:
        failed = True
    elif args.fail_on == "removed" and res["removed"]:
        failed = True
    if args.max_drift >= 0 and (len(res["diverged"]) + len(res["added"]) + len(res["removed"])) > args.max_drift:
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
