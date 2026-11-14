#!/usr/bin/env python3
# Copyright 2026 Flrone. All rights reserved.
"""Drift detector between the vendored Prism UI copy and upstream chen08209/prism_ui.

The vendored copy lives in the ``prism_ui`` Flutter plugin
(``flutter/plugins/prism_ui/lib``): FlClash's whole UI is built on this kit, and the
UI migration moved the fork from ``flutter/lib/ui`` to a real path-dependency so the
package imports resolve as upstream's do. This tool measures how far that copy has
drifted from the upstream commit it was actually taken from, so a sync is a decision
with evidence behind it instead of a manual diff.

Two artifacts live next to this script:

* ``prism_upstream.lock.json``      — the pinned baseline (repo, commit, subject)
  plus the upstream tip that was last reviewed against it.
* ``prism_upstream.manifest.json``  — normalized ``{relative_path: sha256}`` of the
  pinned upstream checkout. Committed so CI can run fully offline and
  deterministically; regenerate it with ``snapshot``.

The baseline is the commit the copy came from, **not** upstream's current tip.
Pinning the tip would report upstream's own progress as our drift and hide which
files we have actually patched; keeping the two apart is what makes the numbers
mean something.

Modes
-----
``check``     (default) Compare the vendored copy against the baseline manifest.
              Exits non-zero when ``--fail-on`` names a non-empty category or when
              ``--max-diverged`` is exceeded. CI runs this on every push.
``upstream``  Compare a fresh upstream checkout against the baseline manifest and
              list what upstream has changed since we vendored. Needs a checkout;
              run it deliberately, not in CI.
``snapshot``  Rebuild the manifest (and lock) from a checkout after a real sync.

Normalization
-------------
Both sides are canonicalized so the *mechanical* consequences of vendoring do not
register as drift:

* ``package:prism_ui/`` and ``package:flrone/ui/`` collapse to one sentinel;
* shader asset keys ``packages/prism_ui/shaders/x`` and ``shaders/x`` collapse to
  one sentinel (the kit compiles into the app, so the package prefix goes away);
* CRLF and bare CR become LF, and a single trailing newline is enforced.

Everything else is real: a differing file is either a local patch or a stale copy,
and the report says which by comparing against the baseline.

Run ``python3 tools/diagnostics/prism_drift.py --help`` for all options.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict

# --- paths -----------------------------------------------------------------
HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
LOCK_PATH = HERE / "prism_upstream.lock.json"
MANIFEST_PATH = HERE / "prism_upstream.manifest.json"

DEFAULT_LOCAL = REPO_ROOT / "flutter" / "plugins" / "prism_ui" / "lib"
DEFAULT_UPSTREAM_REPO = "https://github.com/chen08209/prism_ui.git"

# Package prefixes that mean the same thing on each side of the fork.
# `package:flrone/ui/` is the name the fork used before the FlClash UI migration; the
# vendored copy now imports `package:prism_ui/` like upstream. Deliberately NOT
# including the host app's own package: an accidental `package:fl_clash/ui/` import
# inside the plugin would be a circular dependency, and normalizing it away would
# hide exactly that mistake.
_PACKAGE_PREFIXES = ("package:prism_ui/", "package:flrone/ui/")
_PACKAGE_SENTINEL = "package:__PRISM_UI__/"
# `packages/prism_ui/shaders/x.frag` upstream, `shaders/x.frag` once vendored.
_SHADER_RE = re.compile(r"packages/prism_ui/shaders/")
_BARE_SHADER_RE = re.compile(r"(?<![\w/])shaders/")
_SHADER_SENTINEL = "__SHADERS__/"


# --- normalization ---------------------------------------------------------
def normalize(text: str) -> str:
    """Canonicalize Dart source so the fork rename + asset move are ignored."""
    for prefix in _PACKAGE_PREFIXES:
        text = text.replace(prefix, _PACKAGE_SENTINEL)
    text = _SHADER_RE.sub(_SHADER_SENTINEL, text)
    text = _BARE_SHADER_RE.sub(_SHADER_SENTINEL, text)
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


# --- upstream metadata -----------------------------------------------------
def _git(upstream_dir: Path, *args: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(upstream_dir), *args],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except Exception:
        return ""


def detect_git_dir(upstream_dir: Path) -> Path | None:
    """Walk up from a checkout subdirectory (e.g. ``lib``) to the git root."""
    cur = upstream_dir.resolve()
    for _ in range(6):
        if (cur / ".git").exists():
            return cur
        if str(cur) == str(cur.parent):
            return None
        cur = cur.parent
    return None


def upstream_metadata(upstream_dir: Path) -> dict:
    """Commit, subject, date and package version of the checkout, best effort."""
    meta: dict = {}
    git_dir = detect_git_dir(upstream_dir)
    if git_dir is not None:
        meta["commit"] = _git(git_dir, "rev-parse", "HEAD")
        meta["subject"] = _git(git_dir, "log", "-1", "--format=%s")
        meta["date"] = _git(git_dir, "log", "-1", "--format=%ad", "--date=short")
    pubspec = (git_dir or upstream_dir) / "pubspec.yaml"
    if pubspec.is_file():
        match = re.search(r"^version:\s*(\S+)", pubspec.read_text(encoding="utf-8"), re.MULTILINE)
        if match:
            meta["version"] = match.group(1)
    return {k: v for k, v in meta.items() if v}


def write_lock(commit_meta: dict, ref: str, previous: dict) -> None:
    """Rewrite the lock, keeping the review block a human last wrote."""
    payload = {
        "repo": DEFAULT_UPSTREAM_REPO,
        "vendored_from": {
            "ref": ref,
            **commit_meta,
        },
        "note": (
            "Pinned baseline for Prism UI drift detection: the upstream commit the "
            "vendored copy under flutter/plugins/prism_ui/lib was taken from. Regenerate "
            "with `prism_drift.py snapshot --upstream <checkout>` only after a real sync, "
            "and update reviewed_upstream by hand when the `upstream` mode is re-run."
        ),
        "manifest": "prism_upstream.manifest.json",
    }
    if previous.get("reviewed_upstream"):
        payload["reviewed_upstream"] = previous["reviewed_upstream"]
    LOCK_PATH.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


# --- manifest ---------------------------------------------------------------
def write_manifest(upstream_dir: Path, commit_meta: dict, ref: str) -> Dict[str, str]:
    manifest = collect(upstream_dir)
    payload = {
        "generated_by": "tools/diagnostics/prism_drift.py snapshot",
        "repo": DEFAULT_UPSTREAM_REPO,
        "ref": ref,
        "commit": commit_meta.get("commit", "unknown"),
        "file_count": len(manifest),
        "files": manifest,
    }
    MANIFEST_PATH.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8",
    )
    previous = json.loads(LOCK_PATH.read_text(encoding="utf-8")) if LOCK_PATH.is_file() else {}
    write_lock(commit_meta, ref, previous)
    return manifest


# --- comparison -------------------------------------------------------------
def compare(baseline: Dict[str, str], local: Dict[str, str]) -> Dict[str, list]:
    identical, diverged, added, removed = [], [], [], []
    for key in sorted(set(baseline) & set(local)):
        (identical if baseline[key] == local[key] else diverged).append(key)
    added = sorted(set(local) - set(baseline))
    removed = sorted(set(baseline) - set(local))
    return {"identical": identical, "diverged": diverged, "added": added, "removed": removed}


def render_report(meta: dict, res: dict, local_root: Path) -> str:
    lines = ["Prism UI drift report", "=" * 60]
    lines.append(f"baseline     : {meta.get('ref')} @ {str(meta.get('commit'))[:12]}")
    lines.append(f"baseline files: {meta.get('file_count')}")
    lines.append(f"local root   : {local_root}")
    lines.append("")
    lines.append(f"  identical : {len(res['identical'])}")
    lines.append(f"  diverged  : {len(res['diverged'])}   (patched here, or older than the baseline)")
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


def upstream_report(meta: dict, baseline: Dict[str, str], upstream: Dict[str, str],
                    where: Path) -> dict:
    changed = sorted(k for k in set(baseline) & set(upstream) if baseline[k] != upstream[k])
    added = sorted(set(upstream) - set(baseline))
    removed = sorted(set(baseline) - set(upstream))
    lines = ["Prism UI upstream report", "=" * 60]
    lines.append(f"baseline     : {meta.get('ref')} @ {str(meta.get('commit'))[:12]}")
    lines.append(f"checkout     : {where}")
    lines.append("")
    if not (changed or added or removed):
        lines.append("Upstream has not moved since the baseline: nothing to sync.")
        return {"changed": [], "added": [], "removed": [], "text": "\n".join(lines)}
    if changed:
        lines.append(f"Changed upstream since the baseline ({len(changed)}):")
        for f in changed:
            lines.append(f"  ~ {f}")
        lines.append("")
    if added:
        lines.append(f"New upstream files ({len(added)}):")
        for f in added:
            lines.append(f"  + {f}")
        lines.append("")
    if removed:
        lines.append(f"Upstream dropped ({len(removed)}):")
        for f in removed:
            lines.append(f"  x {f}")
        lines.append("")
    lines.append("Review each file, then either sync it or record why not in docs/prism-upstream.md.")
    return {"changed": changed, "added": added, "removed": removed, "text": "\n".join(lines)}


# --- CLI --------------------------------------------------------------------
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Prism UI drift detector")
    ap.add_argument("mode", nargs="?", choices=["check", "snapshot", "upstream", "report"],
                    default="check",
                    help="check (default), upstream, snapshot, or report (=check)")
    ap.add_argument("--upstream", type=Path,
                    help="upstream checkout or its lib/ directory (snapshot and upstream modes)")
    ap.add_argument("--local", type=Path, default=DEFAULT_LOCAL,
                    help="vendored ui directory (check mode)")
    ap.add_argument("--ref", default="main", help="upstream ref name recorded in the lock file")
    ap.add_argument("--commit", default="", help="upstream commit recorded in the lock file")
    ap.add_argument("--json", type=Path, help="write the result as JSON to this path")
    ap.add_argument("--fail-on", choices=["diverged", "added", "removed", "any"],
                    help="exit non-zero if the named category is non-empty")
    ap.add_argument("--max-diverged", type=int, default=-1,
                    help="exit non-zero if more than N files diverge (default: never)")
    ap.add_argument("--expect-diverged", default="",
                    help="comma-separated file names that must be exactly the "
                         "diverged set: a different file patched instead is a failure, "
                         "even when the count still fits --max-diverged")
    ap.add_argument("--max-drift", type=int, default=-1,
                    help="exit non-zero if diverged+added+removed exceeds this (default: never)")
    args = ap.parse_args(argv)

    if args.expect_diverged and args.fail_on in ("diverged", "any"):
        ap.error("--expect-diverged already fails when the diverged set is not "
                 "exactly the expected one; --fail-on diverged/any would make the "
                 "check fail even when it matches")

    if args.mode == "snapshot":
        if not args.upstream or not args.upstream.is_dir():
            ap.error("--upstream <dir> is required for snapshot and must exist")
        meta = upstream_metadata(args.upstream)
        if args.commit:
            meta["commit"] = args.commit
        if not meta.get("commit"):
            meta["commit"] = "unknown"
            print("WARNING: could not resolve the upstream commit; pass --commit.",
                  file=sys.stderr)
        manifest = write_manifest(args.upstream, meta, args.ref)
        print(f"Wrote baseline manifest: {len(manifest)} files -> {MANIFEST_PATH}")
        print(f"Wrote lock file -> {LOCK_PATH}")
        return 0

    if not MANIFEST_PATH.is_file():
        print(f"ERROR: baseline manifest missing: {MANIFEST_PATH}\n"
              f"Run `prism_drift.py snapshot --upstream <prism_ui/lib>` first.", file=sys.stderr)
        return 2
    meta = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    baseline = meta.get("files", {})

    # The gate must fail closed: an emptied or mis-counted manifest is the one
    # input that turns every category into zero and silently passes CI. The
    # project has lost a JSON file to a truncate-then-throw before.
    problems = []
    if not isinstance(baseline, dict) or not baseline:
        problems.append("the manifest lists no files")
    else:
        declared = meta.get("file_count")
        if declared is not None and declared != len(baseline):
            problems.append(
                f"file_count says {declared} but the manifest lists "
                f"{len(baseline)} files")
    if not meta.get("commit") or meta.get("commit") == "unknown":
        problems.append("the baseline commit is missing or 'unknown'")
    if problems:
        for problem in problems:
            print(f"::error::prism baseline is unusable: {problem}", file=sys.stderr)
        print("ERROR: refusing to compare against a broken baseline; "
              "regenerate it with `snapshot`.", file=sys.stderr)
        return 2

    if args.mode == "upstream":
        if not args.upstream or not args.upstream.is_dir():
            ap.error("--upstream <dir> is required for upstream mode")
        result = upstream_report(meta, baseline, collect(args.upstream), args.upstream)
        print(result.pop("text"))
        if args.json:
            args.json.write_text(json.dumps({"meta": meta, "result": result}, indent=2) + "\n",
                                 encoding="utf-8")
        return 1 if (result["changed"] or result["added"] or result["removed"]) else 0

    local = collect(args.local)
    res = compare(baseline, local)
    print(render_report(meta, res, args.local))
    if args.json:
        args.json.write_text(json.dumps({"meta": meta, "result": res}, indent=2) + "\n",
                             encoding="utf-8")
        print(f"\nJSON written -> {args.json}")

    counts = {k: len(v) for k, v in res.items()}
    failed = False
    if args.fail_on == "any" and any(counts[k] for k in ("diverged", "added", "removed")):
        failed = True
    elif args.fail_on in ("diverged", "added", "removed") and counts[args.fail_on]:
        failed = True
    if args.max_diverged >= 0 and counts["diverged"] > args.max_diverged:
        failed = True
        print(f"\nFAIL: {counts['diverged']} diverged files exceeds --max-diverged {args.max_diverged}.")
    if args.max_drift >= 0 and sum(counts.values()) - counts["identical"] > args.max_drift:
        failed = True
        print(f"\nFAIL: drift exceeds --max-drift {args.max_drift}.")
    if args.expect_diverged:
        expected = {name.strip() for name in args.expect_diverged.split(",") if name.strip()}
        actual = set(res["diverged"])
        if expected != actual:
            failed = True
            missing = sorted(expected - actual)
            extra = sorted(actual - expected)
            print("\nFAIL: the diverged set is not the recorded patch set.")
            if missing:
                print(f"  expected but clean: {', '.join(missing)}")
            if extra:
                print(f"  diverged unexpectedly: {', '.join(extra)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
