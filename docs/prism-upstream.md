# Prism UI: upstream relationship and drift policy

`flutter/lib/ui` vendors a fork of [`chen08209/prism_ui`](https://github.com/chen08209/prism_ui),
a Flutter UI kit. This document records *why* we vendor it instead of depending on
it through pub.dev, *which upstream commit* the copy came from, *what* we have
changed, and *how* to keep the relationship honest.

## Why vendored, not a pub.dev dependency

The upstream package is consumed as a normal `pub` dependency by apps that only need
the widgets it ships. Flrone is not such an app:

* Flrone adds **18 files** that do not exist upstream (a JSON-schema editor, QR
  rendering, a bespoke scaffold, custom glyph icons, a fonts barrel, and the
  top-level `ui.dart`). These are product features, not upstream contributions.
* Flrone **patches six files** in place (see the recorded patch set below). A `pub`
  dependency would force us to either give the fix up or carry a patch layer.
* The shader assets move from `packages/prism_ui/shaders/...` to `shaders/...`
  because the kit is compiled into the app, not resolved from a package namespace.

Vendoring keeps the full source in tree, compiles it as part of the module, and lets
us fork freely. The cost is that drift has to be tracked deliberately — which is
what the tooling in this document automates.

## Baseline (pinned)

| Field                 | Value                                                              |
| --------------------- | ------------------------------------------------------------------ |
| Repo                  | `https://github.com/chen08209/prism_ui.git`                         |
| Vendored from         | `946af6da37bd5ff34046f14477a7a550ad04807e` (2026-11-01, `v0.1.2`)   |
| Files                 | 145 (`lib/**/*.dart`)                                               |
| Upstream tip reviewed | `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185` (2026-11-03), 2 commits ahead |

The baseline is recorded in `tools/diagnostics/prism_upstream.lock.json` and the
normalized file hashes in `tools/diagnostics/prism_upstream.manifest.json`, so drift
is measurable in CI without network access.

**The baseline is the commit we actually vendored, not upstream's tip.** Pinning the
tip would count upstream's own progress as our drift and would hide the difference
between "we patched this" and "we are behind". `3.2.26-pre.3` pinned the tip by
mistake and consequently mislabelled three stale files as deliberate forks; the
numbers below are the corrected ones.

## Drift metrics (current)

Measured with `python3 tools/diagnostics/prism_drift.py check`:

| Category  | Count | Meaning                                                       |
| --------- | ----- | ------------------------------------------------------------- |
| identical | 139   | present in both, byte-identical after normalization            |
| diverged  | 6     | present in both, content differs (our patches, see table)      |
| added     | 18    | local-only — Flrone extensions, not in upstream                |
| removed   | 0     | upstream files we have dropped (should stay 0)                 |

Normalization ignores the package rename (`package:prism_ui/` ≡ `package:flrone/ui/`),
the shader asset move (`packages/prism_ui/shaders/` ≡ `shaders/`) and CRLF/LF, so
none of them counts as drift.

## The recorded patch set

| File                     | Δ        | Why it differs                                                                                                        |
| ------------------------ | -------- | --------------------------------------------------------------------------------------------------------------------- |
| `banner.dart`            | 1 → 3    | `ignoring: !widget.visible` becomes `ignoring: !widget.visible \|\| widget.onTap == null`: a notice with no action must not stand between a press and the page under it. |
| `card.dart`              | existing | Pre-existing local patch, recorded in CI's `--expect-diverged`.                                                       |
| `card_surface.dart`      | existing | Pre-existing local patch, recorded in CI's `--expect-diverged`.                                                       |
| `press_surface.dart`     | existing | Pre-existing local patch, recorded in CI's `--expect-diverged`.                                                       |
| `prism_list.dart`        | +1       | An `// ignore: unnecessary_import` before the explicit `rendering.dart` import. Flutter 3.47.9 re-exports rendering from `widgets.dart`, while 3.47.8 still needs the import. |
| `route_motion_hold.dart` | +1       | The same SDK-compatibility ignore comment before its explicit `rendering.dart` import.                               |

CI enforces this exact set with `--max-diverged 6` and `--expect-diverged` in
`ci.yml` (the diverged set must match exactly, not merely fit the budget). A new
local edit either gets reverted or raises that budget together with an entry in
this table.

## Upstream changes we have not taken

Two upstream commits landed after the vendored snapshot. Both are fixes in the
animation/list layer; neither is required by the drift tooling this preview ships, so
they are queued rather than bundled:

| File                       | Upstream commit | What upstream changed                                                                                    |
| -------------------------- | --------------- | -------------------------------------------------------------------------------------------------------- |
| `collapsible_section.dart` | `e93fec1`       | Header is memoized and unkeyed so it updates in place as a group jumps to the top.                        |
| `keyed_animated_list.dart` | `e93fec1`       | Forwards `scrollCacheExtent` to the sliver and moves enter/leave to `_RowPresence`.                       |
| `route_motion_hold.dart`   | `e93fec1`       | Adds the settle pass (`_settle`, `_settling`, `isUnderway`) so a held update is applied once motion stops. |
| `sheet.dart`               | `63450c0`       | A floating foot matches the top corner when the platform reports no corners.                               |

Note that `dashboard.dart` already passes `scrollCacheExtent`; the vendored
`keyed_animated_list.dart` predates the forwarding, so that argument is currently
dropped when the list is keyed. The sync is therefore a real fix, not just tidying.

Run `python3 tools/diagnostics/prism_drift.py upstream --upstream /path/to/prism_ui/lib`
to re-derive this list; it exits non-zero when the list is non-empty, which is why it
is not part of CI.

## The 18 added (local-only) files

Grouped by purpose — none of these exist upstream:

* **JSON-schema editor** — `json/engine/{json_formatter,json_tree,schema_completion,schema_document,schema_store,schema_validator}.dart`, `json/relaxations.dart`
* **QR** — `qr_code.dart`, `qr_matrix.dart`
* **Scaffold** — `scaffold/scaffold.dart`, `scaffold/scaffold_actions.dart`, `scaffold/scaffold_search.dart`
* **Icons / fonts** — `icons/app_glyphs.dart`, `fonts.dart`
* **Misc widgets** — `list_item.dart`, `null_status_illustration.dart`, `setting_text_card.dart`
* **Barrel** — `ui.dart` (the module's public surface)

## Drift detection tooling

`tools/diagnostics/prism_drift.py` has three modes:

```bash
# Measure the vendored copy against the pinned baseline (CI, offline):
python3 tools/diagnostics/prism_drift.py check --json prism_drift.json

# List what upstream changed since the baseline (needs a checkout):
python3 tools/diagnostics/prism_drift.py upstream --upstream /path/to/prism_ui/lib

# Re-pin after a deliberate sync (writes manifest + lock):
python3 tools/diagnostics/prism_drift.py snapshot --upstream /path/to/prism_ui/lib --ref main
```

CI runs `check` on every push with `--fail-on removed --max-diverged 1` and uploads the
JSON report as an artifact. So: dropping a vendored file fails the build, a second
unrecorded patch fails the build, and ordinary upstream movement does not.

## Sync policy

1. **Do not auto-merge.** Upstream is a moving target; a sync is a reviewed act.
2. **Run `upstream` before any pull** and check every listed file against the table above.
   Take a fix only after `flutter analyze --fatal-infos` and `flutter test` agree.
3. **Re-pin on intent, not on noise.** After copying files, run `snapshot` against the
   new commit, then update `reviewed_upstream` in the lock by hand. A manifest hash
   change without a lock commit change means someone edited the baseline to hide drift.
4. **Keep `removed` at zero.** Dropping a vendored file is a decision, not a refactor
   side effect.
