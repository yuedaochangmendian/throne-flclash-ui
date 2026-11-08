#!/usr/bin/env python3
"""Drops the bundled color-emoji webfont from the sing-box dashboard.

The `noto-color-emoji` woff2 is ~5.4 MB (~10% of the APK) and renders the same glyphs the
device's own emoji font already has. This removes the file and every reference to it: the
@font-face block in the stylesheets and the service worker's precache entry. `font-family`
stacks that name the family are left alone — without an @font-face the WebView falls back to
the system emoji font.

Usage: dashboard_slim.py <dashboard dir>
Fails when the font is present but its references cannot be found, so an upstream rename
breaks the build instead of silently shipping the weight again.
"""

import re
import sys
from pathlib import Path

FONT_GLOB = "*emoji*.woff2"
FONT_RE = re.compile(r"[\w-]*emoji[\w-]*\.woff2")


def main(dest: Path) -> int:
    fonts = sorted((dest / "assets").glob(FONT_GLOB))
    if not fonts:
        print(f"{dest}: no emoji webfont to drop (already slim)")
        return 0

    # 1) the @font-face block that declares the family
    face = re.compile(r"@font-face\{[^{}]*?" + FONT_RE.pattern + r"[^{}]*\}")
    # 2) the service worker precache object referencing the file
    precache = re.compile(r"\{url:\"assets/" + FONT_RE.pattern + r"\",revision:null\},")

    removed_refs = 0
    for css in dest.rglob("*.css"):
        text = css.read_text()
        new, n = face.subn("", text)
        if n:
            css.write_text(new)
            removed_refs += n
    for js in dest.rglob("sw.js"):
        text = js.read_text()
        # either the leading or the trailing comma goes with the entry
        new, n = re.subn(r",\{url:\"assets/" + FONT_RE.pattern + r"\",revision:null\}", "", text)
        if not n:
            new, n = precache.subn("", text)
        if n:
            js.write_text(new)
            removed_refs += n

    names = [f.name for f in fonts]
    if removed_refs == 0:
        print(f"::error::{dest}: found {names} but no @font-face/precache reference — upstream changed shape",
              file=sys.stderr)
        return 1
    for f in fonts:
        f.unlink()
    print(f"{dest}: dropped {names}, {removed_refs} reference(s) stripped")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: dashboard_slim.py <dashboard dir>")
    sys.exit(main(Path(sys.argv[1])))
