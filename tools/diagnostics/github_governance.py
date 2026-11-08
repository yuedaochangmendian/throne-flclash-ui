#!/usr/bin/env python3
"""Read-only audit of the repository's GitHub process against docs/github-workflow.md.

Checks branch/tag naming, tag<->release pairing, stable/preview asset sets,
releases/latest, the in-app updater's repository constant, version/changelog
agreement and the delete_branch_on_merge setting. Known historical exceptions
live in github_governance_baseline.json; remove an id from that file once the
issue is fixed so the check starts failing on regressions.

Output is ASCII so GitHub Actions logs and Step Summary render identically
under any runner locale.

Usage:
    GH_TOKEN=<token> python3 github_governance.py --repo owner/repo
    GH_TOKEN=<token> python3 github_governance.py --strict --format markdown

In CI the workflow supplies github.token (contents: read) and GITHUB_REPOSITORY.
"""

import argparse
import base64
import json
import os
import re
import sys
from pathlib import Path

import requests

API = "https://api.github.com"
TAG_RE = re.compile(r"^v\d+\.\d+\.\d+(-pre\.\d+)?$")
BRANCH_RE = re.compile(r"^(main|feat/.+|refactor/.+|fix/.+|docs/.+|build/.+|chore/.+|dependabot/.+)$")
ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")
OWN_REPO = "yuedaochangmendian/throne-flclash-ui"


def fail(message, code=2):
    print(f"::error::{message}")
    raise SystemExit(code)


class Audit:
    def __init__(self, repo, token, local_root=None):
        self.repo = repo
        self.local_root = Path(local_root) if local_root else None
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "User-Agent": "throne-governance/1",
            }
        )

    def get(self, path, **params):
        response = self.session.get(f"{API}/repos/{self.repo}{path}", params=params, timeout=30)
        if response.status_code != 200:
            fail(f"GET {path} returned {response.status_code}: {response.text[:200]}")
        return response.json()

    def paginate(self, path):
        page, out = 1, []
        while True:
            chunk = self.get(path, per_page=100, page=page)
            if not isinstance(chunk, list):
                fail(f"GET {path} did not return a list")
            out.extend(chunk)
            if len(chunk) < 100:
                return out
            page += 1

    def content(self, path, ref="main"):
        if self.local_root:
            candidate = self.local_root / path
            if not candidate.exists():
                return None
            return candidate.read_text(encoding="utf-8")
        data = self.get(f"/contents/{path}", ref=ref)
        return base64.b64decode(data["content"]).decode("utf-8", "replace")

    @staticmethod
    def finding(fid, message, detail=""):
        return {"id": fid, "message": message, "detail": detail}

    def collect(self):
        findings = []
        branches = self.paginate("/branches")
        tags = self.paginate("/tags")
        releases = self.paginate("/releases")
        repository = self.get("")
        latest = self.get("/releases/latest")

        # 1. Branch naming.
        for branch in branches:
            name = branch["name"]
            if not BRANCH_RE.match(name):
                findings.append(self.finding(f"branch:name:{name}", f"branch {name} breaks the naming convention"))

        # 2. Tag naming + tag/release pairing.
        tag_names = {t["name"] for t in tags}
        release_tags = {r["tag_name"] for r in releases}
        for tag in sorted(tag_names):
            if not TAG_RE.match(tag):
                findings.append(self.finding(f"tag:name:{tag}", f"tag {tag} does not match ^vX.Y.Z(-pre.N)?$"))
            if tag not in release_tags:
                findings.append(self.finding(f"tag:orphan:{tag}", f"tag {tag} has no release"))
        for tag in sorted(release_tags - tag_names):
            findings.append(self.finding(f"release:no-tag:{tag}", f"release {tag} has no tag"))

        # 3. Release shape.
        for release in releases:
            tag, names = release["tag_name"], {a["name"] for a in release["assets"]}
            if release["draft"]:
                findings.append(self.finding(f"release:draft:{tag}", f"release {tag} is still a draft"))
                continue
            has_manifest = "throne-update.json" in names
            abi_ok = all(any(abi in n and n.endswith(".apk") for n in names) for abi in ABIS)
            if release["prerelease"]:
                if has_manifest:
                    findings.append(
                        self.finding(f"release:preview-manifest:{tag}", f"preview {tag} must not carry throne-update.json")
                    )
            else:
                if not (abi_ok and "SHA256SUMS" in names and has_manifest):
                    missing = []
                    if not abi_ok:
                        missing.append("3 ABI APKs")
                    if "SHA256SUMS" not in names:
                        missing.append("SHA256SUMS")
                    if not has_manifest:
                        missing.append("throne-update.json")
                    findings.append(
                        self.finding(f"release:stable-assets:{tag}", f"stable {tag} has incomplete assets", ", ".join(missing))
                    )

        # 4. releases/latest.
        if latest.get("prerelease"):
            findings.append(
                self.finding(f"latest:prerelease:{latest['tag_name']}", "releases/latest points at a prerelease")
            )
        latest_names = {a["name"] for a in latest.get("assets", [])}
        if not {"SHA256SUMS", "throne-update.json"} <= latest_names:
            findings.append(
                self.finding(f"latest:assets:{latest['tag_name']}", "releases/latest lacks manifest assets")
            )

        # 5. Repository setting. An installation token with contents:read does not
        # receive this admin-level field, so a missing field is not a violation.
        if "delete_branch_on_merge" in repository and not repository["delete_branch_on_merge"]:
            findings.append(
                self.finding("settings:delete_branch_on_merge", "merged PR branches are not deleted automatically")
            )

        # 6. Updater contract: the constant must point at this repository.
        updater = self.content("app/src/main/java/io/nekohasekai/sagernet/update/UpdateChecker.kt")
        if updater is None:
            findings.append(self.finding("updater:missing", "UpdateChecker.kt not found"))
        else:
            match = re.search(r'const val REPOSITORY\s*=\s*"([^"]+)"', updater)
            value = match.group(1) if match else "<missing>"
            if value != self.repo:
                findings.append(
                    self.finding(
                        f"updater:repository:{value}",
                        "UpdateChecker.REPOSITORY does not point at this repository",
                        f"found {value}, expected {self.repo}",
                    )
                )

        # 7. VERSION_NAME agrees with the top CHANGELOG heading (preview headings allowed).
        props = self.content("nb4a.properties")
        changelog = self.content("CHANGELOG.md")
        if props and changelog:
            version = re.search(r"^VERSION_NAME=(.+)$", props, re.M)
            heading = re.search(r"^####\s+(\S+)", changelog, re.M)
            if version and heading:
                base = re.sub(r"-pre\.\d+$", "", heading.group(1).strip())
                if base != version.group(1).strip():
                    findings.append(
                        self.finding(
                            f"version:changelog:{heading.group(1)}",
                            "CHANGELOG top section disagrees with VERSION_NAME in nb4a.properties",
                            f"CHANGELOG {heading.group(1)} / VERSION_NAME {version.group(1).strip()}",
                        )
                    )
        return findings


def load_baseline(path):
    if not path or not Path(path).exists():
        return set()
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return set(data.get("baseline", []))


def render(findings, baseline, fmt):
    new = [f for f in findings if f["id"] not in baseline]
    known = [f for f in findings if f["id"] in baseline]
    if fmt == "json":
        return json.dumps({"new": new, "baselined": known}, indent=2)
    lines = [
        "## GitHub process governance audit",
        "",
        "Scope: branches / tags / releases / latest / updater constant / version agreement / repo settings",
        f"New violations: **{len(new)}**; historical exceptions in baseline: {len(known)}",
        "",
    ]
    if new:
        lines += ["### New violations (fix required)", "", "| id | message | detail |", "|---|---|---|"]
        lines += [f"| `{f['id']}` | {f['message']} | {f['detail']} |" for f in new]
    else:
        lines += ["### New violations: none", ""]
    if known:
        lines += ["", "### Historical exceptions in baseline", "", "| id | message |", "|---|---|"]
        lines += [f"| `{f['id']}` | {f['message']} |" for f in known]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY") or OWN_REPO)
    parser.add_argument("--token", default=os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))
    parser.add_argument("--baseline", default=str(Path(__file__).with_name("github_governance_baseline.json")))
    parser.add_argument("--format", choices=("markdown", "json"), default="markdown")
    parser.add_argument("--strict", action="store_true", help="exit 1 on violations not in the baseline")
    parser.add_argument("--local-root", help="read repository files from this checkout instead of the GitHub API")
    args = parser.parse_args()

    if not args.token:
        fail("GH_TOKEN / GITHUB_TOKEN is required")
    audit = Audit(args.repo, args.token, args.local_root)
    findings = audit.collect()
    baseline = load_baseline(args.baseline)
    print(render(findings, baseline, args.format))
    new = [f for f in findings if f["id"] not in baseline]
    if args.strict and new:
        fail(f"{len(new)} governance violation(s) not in the baseline", 1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
