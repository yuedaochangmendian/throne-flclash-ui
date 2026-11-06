#!/usr/bin/env bash
# Publish v<VERSION_NAME> idempotently, riding out GitHub API 5xx.
#
# The release workflow used to call `gh release create` once. Two consecutive
# runs (2026-11-04) died on runner-side 502/500 *after* the APKs were built and
# signed, leaving a half-finished release. This script:
#   * retries every mutating API call three times with a backoff
#   * reuses an existing release/draft instead of refusing the tag
#   * publishes an existing draft (the local-API fallback path)
#   * fails loudly but keeps dist/ as a workflow artifact for manual recovery
#
# See docs/release-runbook.md for the manual path.
set -euo pipefail

: "${TAG:?TAG is required}"
: "${VERSION_NAME:?VERSION_NAME is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"

NOTES="${RUNNER_TEMP:-/tmp}/release.md"
bash buildScript/release_notes.sh "$VERSION_NAME" > "$NOTES"

retry() {
    local attempt
    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -lt 3 ]; then
            echo "::warning::attempt $attempt failed ($1); retrying in 15s"
            sleep 15
        fi
    done
    return 1
}

fail_with_artifacts() {
    echo "::error::the GitHub release API failed three times; dist/ is preserved as a workflow artifact."
    echo "         Re-run this workflow, or follow docs/release-runbook.md to publish locally."
    exit 1
}

# Preview builds stay off releases/latest: the in-app updater follows that
# alias, and a preview must never displace the current stable update manifest.
PRERELEASE_FLAG=()
if [ "${PRERELEASE:-false}" = "true" ]; then
    PRERELEASE_FLAG=(--prerelease)
fi

if gh release view "$TAG" --json id > /dev/null 2>&1; then
    echo "release $TAG already exists: uploading assets instead of recreating the tag"
    retry gh release upload "$TAG" dist/* --clobber || fail_with_artifacts
    if [ "$(gh release view "$TAG" --json isDraft --jq '.isDraft' 2> /dev/null || echo false)" = "true" ]; then
        retry gh release edit "$TAG" --draft=false || fail_with_artifacts
    fi
else
    if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
        # The tag already exists in the repository; do not pass --target.
        retry gh release create "$TAG" dist/* --title "$TAG" --notes-file "$NOTES" \
            "${PRERELEASE_FLAG[@]}" || fail_with_artifacts
    else
        retry gh release create "$TAG" dist/* --target "$GITHUB_SHA" \
            --title "$TAG" --notes-file "$NOTES" "${PRERELEASE_FLAG[@]}" || fail_with_artifacts
    fi
fi

echo "published $TAG"
gh release view "$TAG" --json tagName,isDraft,assets \
    --jq '{tag: .tagName, draft: .isDraft, assets: [.assets[].name]}'
