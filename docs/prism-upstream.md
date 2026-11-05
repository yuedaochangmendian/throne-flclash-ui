# Prism UI: upstream relationship and drift policy

`flutter/lib/ui` vendors a fork of [`chen08209/prism_ui`](https://github.com/chen08209/prism_ui),
a Flutter UI kit. This document records *why* we vendor it instead of depending on
it through pub.dev, *what* we have changed, and *how* to keep the relationship honest.

## Why vendored, not a pub.dev dependency

The upstream package is consumed as a normal `pub` dependency by apps that only need
the widgets it ships. Flrone is not such an app:

* Flrone adds **18 files** that do not exist upstream (a JSON-schema editor, QR rendering,
  a bespoke scaffold, custom glyph icons, a fonts barrel, and the top-level `ui.dart`).
  These are product features, not upstream contributions.
* Flrone has **7 files** that exist upstream but have diverged in place (see below). A
  `pub` dependency would force us to either abandon those forks or carry an unmaintainable
  patch layer.
* The shader assets had to move from `packages/prism_ui/shaders/...` to `shaders/...`
  because the kit is compiled into the app, not resolved from a package namespace.

Vendoring keeps the full source in tree, compiles it as part of the module, and lets us
fork freely. The cost is that we must track drift by hand — which is what the tooling in
this document automates.

## Baseline (pinned)

| Field    | Value                                                                 |
| -------- | --------------------------------------------------------------------- |
| Repo     | `https://github.com/chen08209/prism_ui.git`                           |
| Ref      | `main` tip at snapshot time (one commit past the `v0.1.2` tag)        |
| Commit   | `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185`                           |
| Files    | 145 (`lib/**/*.dart`)                                                 |

The exact commit is recorded in `tools/diagnostics/prism_upstream.lock.json`; the
normalized baseline is committed in `tools/diagnostics/prism_upstream.manifest.json`
so drift can be measured in CI without network access.

## Drift metrics (current)

Measured with `python3 tools/diagnostics/prism_drift.py check`:

| Category | Count | Meaning                                                       |
| -------- | ----- | ------------------------------------------------------------- |
| identical | 138  | present in both, byte-identical after normalization           |
| diverged  | 7     | present in both, content differs (see table)                  |
| added     | 18    | local-only — Flrone extensions, not in upstream               |
| removed   | 0     | upstream files we have dropped (should stay 0)               |

Normalization ignores the intentional package rename
(`package:prism_ui/` ≡ `package:flrone/ui/`) and CRLF/LF differences, so neither
counts as drift.

## The 7 diverged files

| File                     | Δ lines | Disposition      | Why it differs                                                                 |
| ------------------------ | ------- | --------------- | ------------------------------------------------------------------------------ |
| `banner.dart`            | 4       | **Keep (fork)** | Local adds `\|\| widget.onTap == null` so a notice with no action does not intercept presses. Flrone-specific fix. |
| `collapsible_section.dart` | 43   | **Keep (fork)** | Local inlines a `key: ValueKey(group.key)` header instead of upstream's unkeyed "update in place" header. Deliberate rebuild behaviour. |
| `keyed_animated_list.dart` | 38   | **Keep (fork)** | Local drops `scrollCacheExtent` and the `_RowPresence` clip widget, using a direct `SizeTransition`+`FadeTransition`. Simpler enter/leave animation we intend to keep. |
| `route_motion_hold.dart` | 52     | **Keep (fork)** | Local removes upstream's settle/hold machinery (`_settle`, `_applyHeld`, `isUnderway`), keeping a simpler `showFirstContent`. Intentional. |
| `liquid_glass.dart`      | 2       | **Mechanical**  | Shader asset path `packages/prism_ui/shaders/...` → `shaders/...`. Required by the in-app (non-package) layout, not a semantic change. |
| `press_sparkle.dart`     | 2       | **Mechanical**  | Same shader-path move as `liquid_glass.dart`.                                  |
| `sheet.dart`             | 9       | **Sync candidate** | Upstream rounds a floating sheet's foot corners with `float`; local always uses `_sheetCorner`. Upstream's fix is low-risk and could be pulled. |

**Net:** 4 intentional forks, 2 mechanical (vendoring) changes, 1 low-risk upstream
improvement we have *not* taken. No divergence is accidental or unknown.

## The 18 added (local-only) files

Grouped by purpose — none of these exist upstream:

* **JSON-schema editor** — `json/engine/{json_formatter,json_tree,schema_completion,schema_document,schema_store,schema_validator}.dart`, `json/relaxations.dart`
* **QR** — `qr_code.dart`, `qr_matrix.dart`
* **Scaffold** — `scaffold/scaffold.dart`, `scaffold/scaffold_actions.dart`, `scaffold/scaffold_search.dart`
* **Icons / fonts** — `icons/app_glyphs.dart`, `fonts.dart`
* **Misc widgets** — `list_item.dart`, `null_status_illustration.dart`, `setting_text_card.dart`
* **Barrel** — `ui.dart` (the module's public surface)

## Drift detection tooling

`tools/diagnostics/prism_drift.py`:

```bash
# Regenerate the baseline from a fresh upstream checkout (run after a deliberate pull):
python3 tools/diagnostics/prism_drift.py snapshot \
  --upstream /path/to/prism_ui/lib \
  --ref "main" --commit <upstream_commit>

# Measure current drift (runs in CI, informational):
python3 tools/diagnostics/prism_drift.py check --json prism_drift.json
```

CI runs `check` on every push and fails the build if any upstream file is *removed*
locally (`--fail-on removed`) — that is the one change that is never intended.

## Sync policy

1. **Do not auto-merge.** Upstream is a moving target; merges are deliberate, reviewed acts.
2. **Review the 7 divergences before any pull.** Confirm each still needs its local fork;
   the `sheet.dart` floating-foot rounding is the cheapest safe improvement to take.
3. **Re-baseline on intent, not on noise.** Only update `prism_upstream.manifest.json`
   (via `snapshot`) when we have actually synced to a new upstream commit, and record the
   new commit in `prism_upstream.lock.json`.
4. **Keep `removed` at zero.** Dropping a vendored file should be an explicit decision, not
   a refactor side effect — CI guards this.
