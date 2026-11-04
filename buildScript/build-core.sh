#!/usr/bin/env bash
# Build app/libs/ThroneCore.aar from throneproj/Throne with the self-owned kernel
# bridge patched in. Mirrors .github/actions/throne-core/action.yml; the only
# addition is apply-core-patch.sh before the core's own build script runs.
#
#   THRONE_CORE_REF=<sha> bash buildScript/build-core.sh
#
# Requirements: git, go 1.27+, Android SDK/NDK (ANDROID_HOME / ANDROID_NDK_HOME),
# java 17, and sagernet/gomobile v0.1.13 on PATH (gomobile + gobind).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

REF="${THRONE_CORE_REF:-$(sed -n 's/^THRONE_CORE_REF=//p' "$ROOT/nb4a.properties" | tr -d '\r[:space:]')}"
test -n "$REF" || { echo "error: THRONE_CORE_REF not set and not found in nb4a.properties" >&2; exit 2; }

THRONE_DIR="${THRONE_DIR:-$(dirname "$ROOT")/Throne}"
rm -rf "$THRONE_DIR"
git init -q "$THRONE_DIR"
git -C "$THRONE_DIR" remote add origin https://github.com/throneproj/Throne
git -C "$THRONE_DIR" fetch -q --depth 1 origin "$REF"
git -C "$THRONE_DIR" checkout -q --detach FETCH_HEAD

# Land the bridge (additive files only; the Java surface gobind generates stays
# identical, so the app keeps compiling while the throne_* C ABI appears).
bash "$HERE/apply-core-patch.sh" "$THRONE_DIR"

# Same entry point CI uses; outputs the AAR to app/libs/.
DEST="$ROOT/app/libs" bash "$THRONE_DIR/script/build_android.sh"

echo "built $ROOT/app/libs/ThroneCore.aar from $REF + core-patch"
