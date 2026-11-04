#!/usr/bin/env bash
# Apply the self-owned kernel bridge to a Throne checkout. The patch is purely
# additive: new files under core/mobile/ (package mobile). gobind ignores the
# unexported identifiers, so the generated Java surface — and everything already
# compiled against it — is unchanged. What lands is the throne_* C ABI that
# Dart's dart:ffi layer and the android/core JNI shim call.
set -euo pipefail

THONE_DIR="${1:?usage: apply-core-patch.sh <throne-checkout>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

test -d "$THONE_DIR/core/mobile" || {
    echo "error: $THONE_DIR does not look like a Throne checkout (no core/mobile)" >&2
    exit 2
}

cp -R "$HERE/core-patch/core/mobile/." "$THONE_DIR/core/mobile/"
echo "patched $THONE_DIR/core/mobile with the bridge (bridge_calls.go, bridge_runtime.go,"
echo "        dartbridge.go, bridge_symbols.h, dartbridge/include/)"
