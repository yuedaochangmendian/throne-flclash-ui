# Prism UI: upstream relationship and drift policy

`flutter/plugins/prism_ui/lib` holds [`chen08209/prism_ui`](https://github.com/chen08209/prism_ui),
the Flutter UI kit FlClash's dev branch is built on. Since the migration to FlClash v0.9.3's own
interface it is an **upstream package consumed as a path dependency** (`prism_ui:` →
`path: plugins/prism_ui` in `flutter/pubspec.yaml`), not a vendored copy under the app's own
package. This document records *why* we still keep it in tree instead of depending on it through
pub.dev, *which upstream commit* the copy came from, *what* we have changed (nothing: the copy is
byte-identical to that commit), and *how* to keep the relationship honest.

## Why in tree, not a pub.dev dependency

The upstream package is consumed as a normal `pub` dependency by apps that only need the widgets it
ships. Flrone is not such an app:

* FlClash itself carries the kit as a **submodule at `plugins/prism_ui` and a path dependency**, and
  this fork is a whole-tree copy of FlClash's `lib`; keeping the same shape means upstream's imports
  and any upstream-side plugin wiring stay valid without translation.
* An in-tree copy is what the **drift gate** measures. A resolved `pub` package would move silently
  whenever the pubspec constraint allowed a newer version, so "the copy moved" and "we patched it"
  would stop being distinguishable — the opposite of what this document exists to keep honest.

Keeping the package in tree costs drift bookkeeping — which is what the tooling in this document
automates. The copy is kept byte-identical to upstream so that bookkeeping stays trivial.

## Baseline (pinned)

| Field | Value |
| --- | --- |
| Repo | `https://github.com/chen08209/prism_ui.git` |
| FlClash v0.9.3 pins | `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185` (2026-11-03, `.gitmodules` submodule `plugins/prism_ui`) |
| Drift baseline (`vendored_from`) | `5d8ed7ab674ed2011adf94a7e41aff6d705e9cb6` (2026-11-06, `fix(press): fade a press the tap drops after winning`) |
| Files | 145 (`lib/**/*.dart`) — the whole upstream package is present |
| Upstream tip reviewed | `5d8ed7ab674e` — 0 commits ahead of the baseline as of the last review (2026-11-07) |

The baseline is recorded in `tools/diagnostics/prism_upstream.lock.json` and the normalized file
hashes in `tools/diagnostics/prism_upstream.manifest.json`, so drift is measurable in CI without
network access.

**The baseline is the commit we actually took the copy from, not FlClash's submodule pin and not
upstream's tip.** Pinning the tip would count upstream's own progress as our drift and would hide
the difference between "we patched this" and "we are behind". The baseline sits three commits ahead
of the pin FlClash v0.9.3 records, which is deliberate: the copy includes the fixes those commits
carry.

## Drift metrics (current)

Measured with `python3 tools/diagnostics/prism_drift.py check` (the default local root is now
`flutter/plugins/prism_ui/lib`):

| Category | Count | Meaning |
| --- | --- | --- |
| identical | 145 | present in both, byte-identical after normalization |
| diverged | 0 | present in both, content differs — none; the copy carries no local patch |
| added | 0 | local-only files — none; the package is exactly upstream's file set |
| removed | 0 | upstream files we have dropped (must stay 0) |

Normalization ignores CRLF/LF and the shader asset prefix, so neither counts as drift.

The FlClash UI migration reverted both patches in one pass, and `press_surface.dart` came back as
the pre-`5d8ed7ab` shape — it looked like local drift but was really a lost upstream fix, because the
baseline commit *is* that fix (`fix(press): fade a press the tap drops after winning`). Re-applying
the same two lines restores the file to the baseline byte-for-byte, so it does not appear in the
diverged set at all. `banner.dart` was re-applied at the same time as a deliberate local patch, and
has since been **reverted**: the patch traded swipe-to-dismiss for tap pass-through, and upstream's
own behaviour won. Both files now match the baseline byte-for-byte, so the diverged set is empty.

## The patches this fork used to carry

Both were present in the pre-migration vendored copy under `flutter/lib/ui` and had to be carried
across the move to `flutter/plugins/prism_ui/lib`. Neither is a local patch now: the first was
**reverted** and the second turned out to be upstream's own fix.

| File | vs baseline | Why |
| --- | --- | --- |
| `banner.dart` | **0 — reverted** | The old local patch added `\|\| widget.onTap == null` to `ignoring:`, so an action-less notice would not stand between a press and the page under it. `IgnorePointer` is all-or-nothing: it removed the banner from hit testing entirely, so the drag recognisers behind it never ran — swipe-to-dismiss and drag-to-stretch stopped working and six upstream banner tests failed. Upstream's shape (a plain `ignoring: !widget.visible` over a `HitTestBehavior.opaque` detector) is what its own "a banner takes presses and swipes anywhere on it" test pins: the banner is a solid surface that consumes the press, and a tap with no action has nothing to run. That trade — accepting the press rather than falling through to the page — is upstream's, and the copy now follows it. |
| `press_surface.dart` | **0 — upstream's own fix** | The tap recogniser gets its `onTapCancel` wiring (`..onTapCancel = _cancelPress`, and the matching `..onTapCancel = null` on teardown): a press the tap drops after winning the arena must fade out instead of staying lit. Upstream landed exactly this in `5d8ed7ab`, so applying it makes the file identical to the baseline. |

So the gate needs no `--expect-diverged` identity pin: `--fail-on removed --max-diverged 1` is what
CI runs. The budget of one is headroom for a future local patch, not a claim that one exists; a new
local edit either gets reverted or raises the budget together with an entry in this table.

With `banner.dart` back to upstream's content, all 26 cases in `flutter/test/widgets/banner_test.dart`
pass, including the six the patch broke — the swipe-up dismiss, the short-drag spring-back,
"a banner takes presses and swipes anywhere on it" and the drag/auto-dismiss interaction cases, which
all need the banner to own its hit area. The test file is FlClash's own (it drives the widget through
`fl_clash/ui`), so it pins the behaviour the app ships, not only the package's.

## Upstream changes we have not taken

None as of the last review: `reviewed_upstream.commits_ahead` is 0 — `e93fec1`, `63450c0` and
`5d8ed7ab` are all in the baseline, and the two upstream test files and their helpers
(`TestApp`/`HostScaffold`) came along with them.

Run `python3 tools/diagnostics/prism_drift.py upstream --upstream /path/to/prism_ui/lib` to
re-derive the list; it exits non-zero when the list is non-empty, which is why it is not part of CI.

## The UI layer the app keeps

`flutter/lib/ui/` is no longer a vendored copy of the kit. It is FlClash's own adapter over the
package — `ui.dart` re-exports `package:prism_ui/prism_ui.dart` plus a handful of app widgets
(`delay_color`, `emoji`, `fonts`, `list_item`, `null_status_illustration`, `profile_id`, `qr_code`,
`scaffold/scaffold.dart`, `setting_text_card`), and `icons/icons.dart` re-exports
`package:prism_ui/icons/icons.dart` plus the app's own `app_glyphs.dart`. Those files are part of the
FlClash fork, not of Prism UI, so they are out of scope for this drift policy.

## Drift detection tooling

`tools/diagnostics/prism_drift.py` has three modes:

```bash
# Measure the local copy against the pinned baseline (CI, offline):
python3 tools/diagnostics/prism_drift.py check --json prism_drift.json

# List what upstream changed since the baseline (needs a checkout):
python3 tools/diagnostics/prism_drift.py upstream --upstream /path/to/prism_ui/lib

# Re-pin after a deliberate sync (writes manifest + lock):
python3 tools/diagnostics/prism_drift.py snapshot --upstream /path/to/prism_ui/lib --ref main
```

`check` defaults to `flutter/plugins/prism_ui/lib` — the package's real location. CI runs `check` on
every push with `--fail-on removed --max-diverged 1` and uploads the JSON report as an artifact. So:
dropping a file fails the build, a second unrecorded patch fails the build, and ordinary upstream
movement does not. `--expect-diverged` is not used — the diverged set is empty, and pinning an empty
set by name would only make an accidental one look sanctioned.

## Sync policy

1. **Do not auto-merge.** Upstream is a moving target; a sync is a reviewed act.
2. **Run `upstream` before any pull** and check every listed file against the table above. Take a
   fix only after `flutter analyze --fatal-infos` and `flutter test` agree. Nothing is pending out of
   the table: it records two files that are no longer patched, not two exceptions to carry forward.
3. **Copy upstream files verbatim.** There is no patch to re-apply: `banner.dart` and
   `press_surface.dart` both match the baseline byte-for-byte, so a straight copy is already
   correct. Run `check` afterwards — any file that still diverges is a copy that went wrong, not a
   patch to keep.
4. **Re-pin on intent, not on noise.** After copying files, run `snapshot` against the new commit,
   then update `reviewed_upstream` in the lock by hand. A manifest hash change without a lock commit
   change means someone edited the baseline to hide drift.
5. **Keep `removed` at zero.** Dropping a file is a decision, not a refactor side effect.
