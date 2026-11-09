#### 3.3.2

Development notes for the next release. This section will be finalized once the 3.3.1 post-release device matrix and the 3.3.2 scope are closed.

* **Speed tiles and delay tests follow FlClash.** The dashboard keeps FlClash's 1.45 tile ratio with the traffic chart filling the area under the title. Queued proxies show a clock, the running group shows a spinner, finished nodes show their delay, and Test all runs as a visible queue in both grid and list layouts
* **Rule JSON import uses the same multiline dialog as rule fields.** The import flow opens in the same title/description/text-field/action layout as the IP CIDR editor, while retaining schema parsing and the route/DNS preview
* **The Kotlin bridge namespace is now `io.flrone`.** Core, model, bridge, Flutter host, manifest, ProGuard rules, tests, JNI names, audit scripts and live docs moved from `io.throne.bbox`; the existing `io.flrone/box` MethodChannel is unchanged
* **DNS rule import has a dialog regression test.** The test enters the JSON in the same dialog field and taps its actual Import action instead of bypassing the UI path
* **Rule and proxy interactions are tightened.** JSON import now uses the same multiline dialog as the rule fields; the node speed-test panel hides IP check, test kind and scope; clicking a node delay shows a visible running spinner until the test finishes; and upload/download charts use distinct colors
* **The follow-up FlClash and Throne parity round lands.** The speed panel keeps both upload (tertiary) and download (primary) curves after a test finishes; proxy cards consume the live test session so queued nodes show clocks and only the active node spins while `groups.test` stays pending for the whole run. Outbound IP details use the newest of the IP and quality timestamps, JSON import classifies route and DNS rules without a kind picker, and Node presets now match Throne for Android's mode-dependent Mux/Xray rows, fragment gating, uTLS choices, TLS-trick scope and combined HTTP/2 plus QUIC section
* **Review cleanup removes the duplicate latency path and closes two edge cases.** Retesting a node now ignores the previous finished session until the new session starts, mixed route/DNS imports validate each rule against the correct schema instead of producing false errors, and the orphaned fire-and-forget test methods are gone so only the awaitable bridge path remains
* **Preview publishing follows successful main CI automatically.** `release.yml` now listens for the completed `CI` workflow, verifies the tested commit is still `main`, skips an already-published tag, and publishes the next `vX.Y.Z-pre.N` GitHub prerelease with the existing signed asset and no `throne-update.json`; stable releases remain manual or tag-driven
* **GitHub validation is no longer duplicated.** `ci.yml` runs feature branches only through their pull request and reserves push runs for `main`, so one commit no longer creates both push and pull-request copies of the same build, Flutter tests and audit artifact uploads
* **Preview and stable share one package identity and one release workflow.** Both channels now build with `PACKAGE_NAME` (`com.throneflclash`) and the same release signing key, so a preview can upgrade a stable install in place. `release.yml` handles `channel=preview|stable`; the separate preview workflow is removed while GitHub prereleases, artifact-only builds and the no-manifest preview contract remain intact
* **Verification:** `main@fa3a18db` CI and CodeQL are green, the unified preview build `3.3.2-pre.11` is published, and 424 Flutter tests pass on this follow-up branch. The 3.3.1 physical-device matrix remains tracked in Issue #17; the 3.3.2 baseline was closed in Issue #22

#### 3.3.1

The first stable release since 3.3.0. Previews pre.1-pre.23 were the test bed. CI, release-candidate packaging, signature verification and the x86_64 upgrade check passed; the remaining physical-device regression matrix is tracked in Issue #17.

* **The Dart driver owns the core end to end.** Start, stop and reload are serialized; the running core handle is registered with the host, adopted after a Flutter-engine restart, and closed by the service when the UI is gone. A lost core no longer leaves the start button lying or a second box fighting over the same TUN
* **The data plane moves closer to Room.** Route profiles are read over `dart:ffi` with a transparent channel fallback; the schema gate checks the columns every query names, and closed, invalidated or concurrently used SQLite handles now fail safely instead of reading freed memory
* **The notification becomes configurable.** A dedicated Notification page exposes title and content templates, speed and traffic switches, the service group and the button picker. Templates render `{title}`, `{up}`, `{down}`, direct and total counters, and multi-line content uses BigText; the pre.17 ICU crash is covered by JVM tests and the Kotlin regex audit
* **The IP card is faster and richer.** The quality chain reports each answer as it lands and no longer waits on a silent source; the outbound detail page adds an explicit, on-demand Bettbox-style lookup with merged geography/organisation fields and a bounded fraud-risk bucket
* **Routing tools catch up with Throne.** The rule editor gains the upstream scalar pickers, keeps unknown legacy values rather than dropping them, imports sing-box rule fragments and DNS `dns.rules` fragments, and edits list members one per line. Route summaries and condition tokens follow Throne for Android
* **Memory and startup work use Android's accounting.** Process RSS/PSS and the core's own memory are reported separately, startup builds the config while the service comes up, and the pinned dashboard build is 5.4 MB smaller without the bundled color-emoji font
* **UI and core stay aligned with upstream.** The Prism sync, Throne core 1.4.1 pin, Flrone identifier unification and Bettbox runtime guards from the preview line are included. The in-app updater now points at this repository
* **Release and repository checks are auditable.** The AAR channel surface is measured against a budget, the dashboard is pinned, preview/stable release shapes are validated, and governance checks cover the updater constant, tags, assets and changelog/version agreement
* **Verification:** `flutter analyze --fatal-infos` is clean, 387 Flutter tests pass, both CI jobs are green, and `channel_audit`, `symbol_audit`, `ffi_regression_test`, `settings_audit`, `schema_audit`, `generated_models_check`, `kotlin_regex_audit`, `aar_channel_audit` and `py_syntax_check` pass. The lightweight QR-scanner rewrite (PR #16) is deliberately not part of 3.3.1 until its single-code, multi-frame, denied-permission and back-navigation checks have run on an Android device
* **Verification boundary:** CI, the signed release-candidate build, ABI/SHA-256/signature checks and an x86_64 API 35 upgrade test passed. The arm64/TV matrix in `docs/device-checklist.md` remains tracked in Issue #17 and must be completed immediately after publication; the maintainer explicitly approved this release before those remaining checks were completed

#### 3.3.1-pre.23

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one is the boundary round from the architecture review: a pinned and slimmed dashboard, an audited AAR channel surface, and a core that a Flutter-engine death no longer leaves unowned. No UI change.

* **The dashboard build is pinned and 5.4 MB lighter**: `.github/actions/sing-box-dashboard` used to pull the moving `gh-pages` head on every build — the only upstream that was not pinned. It now downloads `SagerNet/sing-box-dashboard` at `d77c2f016a7681aa1704e9f83c69139edb230c97` (2026-10-11), the same way `THRONE_CORE_REF` pins the core. `buildScript/dashboard_slim.py` then deletes the color-emoji woff2 (5.4 MB, roughly 10% of the APK), strips its `@font-face` and its `sw.js` precache entry, and keeps the CSS `Noto Color Emoji` fallback so the WebView uses the device's own glyphs: 7.9 MB -> 2.5 MB. The script is idempotent and fails the build if a future pinned ref no longer carries the expected font and CSS shapes, rather than silently shipping the full bundle
* **Binary-only channels are audited**: `channel_audit.py` sees method names in source, but `io.flrone/*` channels registered inside a vendored AAR were invisible — exactly the `ghostty` / `openconnect` / `terminal` gap the pre.19 note left open. `tools/diagnostics/aar_channel_audit.py` scans every such string in a given AAR / JAR / APK / DEX and in `flutter/lib` against the budget in `aar_channels.txt`; CI runs it on the Flutter AAR and on every freshly built `ThroneCore.aar`. An unknown name fails the push, so a ref bump that widens that surface cannot land unnoticed
* **An engine death no longer strands the core**: the FFI driver registers the running Instance's numeric handle with the host over `ffi.handle` once a start holds, and clears it on every stop, failed start and dispose. A stop from a widget, tile or notification in ffiMode is answered by a `serviceStop` event while the UI is attached; once `cleanUpFlutterEngine` has run there is no subscriber, so `BaseService.stopRunner` closes the adopted handle through a new `Core.closeInstance` JNI thunk over `throne_Instance_close` instead of leaving the tunnel up until the process dies. `ffi.mode` returns the handle to a new engine, which adopts the still-running core through `KernelWorker.adoptInstance` rather than building a second box on the same tun. `docs/bbox-bridge.md` records the contract, and four new handshake tests pin registration, host stop, adoption and a stale handle
* **Checked**: `flutter analyze --fatal-infos` clean, **387 tests pass**, CI green on both jobs; `channel_audit`, `symbol_audit`, `ffi_regression_test`, `settings_audit`, `schema_audit`, `generated_models_check`, `kotlin_regex_audit`, `aar_channel_audit` and `py_syntax_check` all green; the pinned dashboard slims 7.9 MB -> 2.5 MB and is idempotent
* **Still needs a device**: no Android smoke test ran here. Kill the UI while the VPN is up, stop it from the notification, then reopen the app — the tunnel should close on the stop and, if it was left running, come back without a second box fighting over the tun

#### 3.3.1-pre.22

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one fixes the two things found on pre.21: a row that stood out on the rules screen, and an IP card that held its result back.

* **The batch-add row reads like its neighbours**: `Batch add simple rules` carried the dialog title's style — 20dp emphasized — while the rows around it (Add rule, Reorder rules, Restore default rules) are 17dp list titles, so one row of the rules section stood out bigger and heavier. It is a list title now, and the dialog keeps the title3 style every dialog on these pages uses
* **The IP card shows each quality answer as it lands**: the six-source chain delivered one result at the end, so the type and quality chips sat behind skeleton pills — and on a refresh hid the answer the card already had — until the chain converged. `lookupIpQuality` now reports the answer it would deliver as it arrives: the first inferred one as soon as a source speaks, then the precise one that replaces it. The chips update in place the moment anything is known, and a running lookup refines what is on the card instead of blanking it. The lookup's own outcome is unchanged — the future still completes with the precise answer or the first inferred one, so cache writes, expiry and the failure cooldown read the same record — and a new `ip_quality_test` pins the two-stage report
* **Checked**: `flutter analyze --fatal-infos` clean, **383 tests pass**, CI green on both jobs. On a device: the rules screen's four rows at one size, and the status card's chips appearing as soon as a source answers and staying put through a refresh

#### 3.3.1-pre.21

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one is the font-size fix on the settings rows, and nothing else.

* **A row's value now reads at its label's size.** pre.20's rule editor showed the name field at 17dp and the picker values beside it at 11dp bold — `ListRow` sizes its trailing slot for side marks (caption2 emphasized, the size a chevron wants), while `FormRow` keeps its value in the title slot and `ListItem.options` shows its value through a body-size button. Three conventions shared one page, and the value read as a footnote next to its own label. `context.listValueStyle` is the picker value now — body size, secondary colour — and every hand-built value carries it: the rule editor's type / target / outbound / action / reject-method / strategy rows, the route editor's outbound row, node tuning, auto selector, group settings, profile details, the protocol form's picker rows, the test panel, the memory panel and the egress quality failures. 27 rows across ten files
* **Left as it is**: `ListItem.input` rows (Throne settings, backup) draw their value inside prism's `list_item.dart` at the side style; moving those needs a second drift patch against the vendored copy, so they stay 11dp bold for now
* **Checked**: `flutter analyze --fatal-infos` clean, **382 tests pass** (the parallel backoff flake stayed quiet this round), CI green on both jobs. The acceptance check is visual: install this build, open a saved rule, and the name field and every picker value should read at one size

#### 3.3.1-pre.20

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one closes out pre.19's two loose ends — the IP card reports one source, the rule editor folds Advanced away — and then takes a structural pass over the code the previous previews landed. No behaviour change beyond those two UI decisions.

* **The IP card reports the probe that answered**: the Bettbox-derived enrichment block is gone — `ip_enrichment.dart` (284 lines: three detail sources, the field-wise merge, the scamalytics risk score) and its 195-line test are deleted, and the two parallel source rows collapse into one. The card shows whichever probe actually answered, so an unanswered egress probe can no longer sit next to a confident-looking quality row. The automatic six-source quality path is untouched
* **The rule editor reads as Rule / Match / Advanced**, with Advanced collapsed by default, the ThroneForAndroid shape. Picker dialog titles and option labels share `AppTextStyle`, so every `SimpleDialog` in the page lays its rows out at one size
* **`pages/routes.dart` becomes five files.** It held four pages, the rule-text formatters and the enum tables in 1395 lines — the only page module under `lib/pages/` that was not one page. `route_texts.dart` keeps the tables and the pure formatters (`ruleName`, `outboundToken`, `routeActionColor`, `ruleActionText`, `ruleConditions`, `ruleRowSubtitle`); `route_profiles.dart`, `route_editor.dart`, `rule_order.dart` and `rule_editor.dart` are one page each, carrying the dialog only it opens (`_BatchAddDialog`, `_MultiChoiceDialog`, `_RuleSetDialog`). `widgets.dart` exports the five, so no call site changed
* **`RuleEditorPage.build` is 14 lines instead of 250.** Match and Advanced used to sit four levels inside `children: [if (custom) ...[if (_advancedOpen) ...[`. The rule shape comes from getters now (`_isSimple` / `_isEndpoint` / `_isCustom` / `_simpleKind`), and `build` is a `FormPage` over `_ruleSection()`, `_simpleSections()` and `_customSections()`. Lines indented eight levels or more drop from 83 to 29
* **`ruleConditions`' scalar branch loses a test that could not fail**: `raw?.toString().trim() is String` is true by type, and the same string was trimmed three times. It is a plain if/else now, same output
* **The kernel lifecycle has one attach path and one teardown path**: `initialize` and the tests' `debugAttach` carried the same four subscription lines twice, and a failed start nested eight cleanup statements five levels into a `catch`. Both are `_attach` / `_detach` now and the catch is two lines. Four declarations nothing referenced are gone: `readCString` and the private `_cstrPublic` behind it (the generated bindings carry their own `_cstr`), `configEncoder`, and `dnsStrategies` — the rule editor's enum table is the one source for strategy values
* **Checked**: `flutter analyze --fatal-infos` clean; **382 tests pass** and coverage is 54.69% (floor 40%) on a full run — 15 fewer than pre.19, because the deleted enrichment suite was exactly those 15. A parallel run can trip the backoff test described below, which passes 13/13 with its file alone (three runs). `channel_audit`, `symbol_audit`, `ffi_regression_test` and `generated_models_check` green; neither side of the bridge changed
* **Still needs a device**: no Android smoke test ran here, same as pre.17 and pre.19. Installing this build, starting the VPN, opening a saved rule and folding Advanced back open remains the acceptance check
* **Known, unfixed**: `kernel_handshake_test.dart` is flaky when the suite runs in parallel — `a manual start during the recovery backoff rebuilds, not swallows` depends on real 5/20/80 ms delays. It passes 5/5 alone and failed 2 of 4 full runs, including one on a pages-only change. Replacing `Future.delayed` with a fake clock is the fix, and it is test infrastructure, not this run

#### 3.3.1-pre.19

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one lines the rule editor up with Throne for Android and adds Bettbox-style, on-demand IP detail and risk lookup to the outbound card.

* **Rule conditions become pickers instead of free text**: five fields — `ip_version`, `network`, `protocol`, `reject_method`, `strategy` — are now `SimpleDialog` option rows whose value sets are lifted verbatim from Throne's `arrays.xml`. `ip_version` stores `4`/`6`, not the `ipv4`/`ipv6` hints the text box used to accept; `network` gains `icmp`; `protocol` carries the full upstream set; `reject_method` and `strategy` keep an empty first "unset" option. Throne's `ensureValue` is reproduced: a rule saved with a value the picker does not know (an older `ipv4`, say) has that value appended as a live option rather than dropped, so opening and saving an old rule cannot lose it. Picking the unset option removes the key instead of writing an empty string. `action` gains `hijack-dns`, keeps the existing `bypass`, and uses the same helper
* **Bettbox-style IP detail, on demand**: `common/ip_enrichment.dart` adds a self-contained enrichment layer — three detail sources (`ip-api.com`, `get.geojs.io`, `api.ip.sb`) parsed into a field-wise `merge` that fills gaps without overwriting, plus scamalytics `Fraud Score` parsed into low / medium / high / very-high buckets (clamped to 0..100, HTML comments ignored). It is wired into the **Outbound IP** detail page behind an explicit look-up action: nothing fires on the dashboard's automatic refresh path, so the request-count, URL, wave-timing and pixel-height assertions in `ip_quality_test.dart`, `status_panel_test.dart` and `status_panel_parity_test.dart` are untouched. The automatic quality path stays on its original six-source hedged chain; the Bettbox source list is a switchable, on-demand layer. Source labels pass through as given — Bettbox's Hong Kong / Macao / Taiwan country-code rewriting is deliberately **not** ported
* **Pinned and checked**: pure-function tests lock the rule value sets, `ensureValue`, unset labels, key removal and a legacy `ipv4` render; the enrichment module's tests cover all three detail parsers, field merge, risk buckets, all-sources-failing, a malformed single source, JSON round-trip, region pass-through and cancellation. A first CI run caught one inverted assertion in the new test (the implementation was right); a test-only follow-up commit fixed it. The branch now also parses and analyses locally against Dart 3.13.7 under `flutter_lints` before CI. Real CI: `flutter analyze` No issues found, **397 tests passed**, coverage **54.75%** (floor 40%, `lib/common` 97.71%)
* **Still needs a device**: no Android smoke test ran here. The rule pickers and the on-demand lookup are UI paths, so installing this build, opening a saved rule and running the Outbound IP look-up remains the acceptance check

#### 3.3.1-pre.18

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one fixes the pre.17 startup crash: on a real device the VPN service could not start at all.

* **The service starts again.** The one-pass placeholder render introduced in the pre.14 review round shipped in pre.17 as `Regex("\{([A-Za-z]+)}")` — the closing `}` was never escaped. Desktop `java.util.regex` accepts a lone `}`, but Android's `Pattern` delegates to ICU4C, which rejects it with `PatternSyntaxException` at `PatternNative.compileImpl`. Because that `val` sat in `ServiceNotification`'s `companion object`, the failure surfaced as `ExceptionInInitializerError` the moment the class loaded, breaking `VpnService.onStartCommand` → `startProxy` before the core ever ran: an installed pre.17 crash-looped six times in six seconds and the service never left `service: idle`. CI stayed green because `app:testOssDebugUnitTest` runs on the JVM, where the same literal compiles and matches `{up}`. Both braces are now escaped, and the render moved into `NotificationTemplate`, a plain Kotlin object with no Android dependency, so a broken template can degrade the notification text without taking the VPN service down with it
* **Two gates pin the gap.** Six JUnit tests lock the render contract (all seven built-in keys, unknown keys left as written, a value containing `{up}` not re-substituted, the ICU-legal pattern itself), and `tools/diagnostics/kotlin_regex_audit.py` runs in CI to reject an unescaped standalone `}` in any `Regex("…")` literal while leaving legal `{n}` quantifiers alone (nine self-tests; 52 existing literals pass clean). Neither substitutes for a device: only ICU on Android reproduces the difference, so **installing this build and starting the VPN remains the acceptance check**

#### 3.3.1-pre.17

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one is a user-requested UI round: the notification rows get a page of their own, the diagnostics feature goes away, and the route screens read like Throne's.

* **Notification settings move up a level**: the seven service-notification rows (group name, proxy/direct speed, traffic total, the two templates, the button picker) leave the General page for their own **Notification** entry on the settings list, one tap from the drawer like every other page. The General page keeps the connection and behaviour rows
* **The diagnostics feature is deleted**: the settings entry, the network-quality and STUN pages and the domain-resolution page are gone — and the whole chain behind them, because none of it had another consumer. Dart loses `dnsResolve` on the box, the driver's `resolveDomains` and its short-lived lookup isolate; Kotlin loses the `dns.resolve` handler, the `dnsResolve` capability, `BboxResolve` and `DomainResolver`, the AIDL's `resolveDomains` method and `ICoreService`'s override. The C ABI's `Mobile.resolveDomains` stays in the core patch untouched (the throne_* surface is not the UI's to prune); `docs/bbox-bridge.md` records the removal. The dashboard's IP-quality card is unaffected — it never ran through the diagnostics screens
* **The route screens read like Throne's** (`RouteTexts.kt` / `layout_route_rule_item`): a profile row now summarises as `Default: proxy · 3 rules` instead of `Remote · 3 rules`; a rule row carries Throne's two lines — the action on top in the route palette (`route → direct` blue, direct green, `reject (drop)` red, the config purple, night variants lifted) and the conditions under it in the desktop's token language (`suffix: google.com +2 · rule-set: geosite-ir`, first value plus a count, same field order as upstream). Both wire shapes grow `defaultOutbound` so the summary is identical from FFI and channel

#### 3.3.1-pre.16

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one is the review round over the review round: two agents audited the lifecycle serialization, the data-layer fixes and the prism sync as landed, and seven findings came back.

* The two that mattered. **A concurrent reader could call into a closed sqlite handle**: the read-failure eviction closes the connection, but a second overlapping `list()` still held the same reader and would run its query against freed memory (a deterministic interleaving — two route screens and one failing read — not a rare race). `SqliteDatabase` now refuses every statement on a closed handle, which also closes the pre-existing dispose/invalidate overlap. **A lost core made the start button lie**: the worker's `lost` report leaves the instance handle in place on purpose (the recovery reads it), so the new double-start guard read "dead" as "running" and silently swallowed a user's manual start during the recovery backoff — while the swallowed start still bumped the epoch and dissolved the recovery behind it. A lost flag now separates dead from running; the epoch only counts effective transitions, so guarded no-ops can no longer stand a recovery down
* Recovery semantics restored and pinned: `serviceStop()` reports a failed service stop again (the serialization round had swallowed it), the dashboard still says Stopped either way; three new tests cover the lost→rebuild chain, a manual start landing inside the backoff window (it builds), and a start queued behind an unwinding start (the op-level guard is what stops the orphaning — an entry-level guard would pass that test, and previously none could fail)
* Smaller: `Isolate.spawn` failing on its own no longer leaks both receive ports; `KernelWorker.dispose` is idempotent and its error can no longer surface through `unawaited`; the read-demotion comment now states the real trade (no result codes → any read failure demotes, the channel answers identically); the ip-api comment names integrity — not secrecy — as the thing cleartext gives up, and where a forged answer ends up (the quality card, display only); `prism_drift.py` refuses the `--expect-diverged` + `--fail-on diverged/any` combination that could never both hold; the prism baseline records the full 40-char sha; and the changelog's preview-coexistence sentence now scopes itself to tag-path previews

#### 3.3.1-pre.15

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one catches the project up with its two upstreams: the Prism UI sync that queued behind the drift tool, and the Throne core pin moving to 1.4.1 after an API-surface evaluation.

* **Prism sync**: the three upstream commits that queued while the drift tooling was built are in the vendored copy — the feed/list fade fix (`e93fec1`), the sheet's cornerless-display foot rounding (`63450c0`), and the press fade a dropped tap runs (`5d8ed7ab`; our `press_surface.dart` lacked the `onTapCancel` wiring exactly as upstream found). The drift baseline is re-snapshotted at `5d8ed7ab`: 144 identical, `banner.dart` still the only local patch. The upstream test files and their helpers (`TestApp`/`HostScaffold`) come along, so the regressions they pin are pinned here too; `flutter_localizations` joins the dev dependencies for the helper's delegate
* **Core pin moves** `36b6bc4` (10-31) → `3bbe551d` (the `1.4.1` tag, 11-06, 36 commits). The evaluation that cleared it: the self-owned `throne_*` bridge is applied as purely additive file copies with zero imports of core internals, `core/mobile` is **byte-identical** between the two refs (63 exported symbols unchanged — the desktop's new connections/warp/routing APIs live outside the gomobile surface), and `build_android.sh` is unchanged, so the AAR's Java contract and the Dart FFI ABI both survive untouched. What arrives is the dependency wave the 36 commits rode in on: sing-tun, xray-core and sing-box all moved to newer Throne forks (utls key-share fix, wireguard stall fix, XHTTP extra/import compatibility, DNS-tunnel and masque work)
* **Upstream comparison, for the record**: ThroneForAndroid's log-export crash-loop fix (`3c4f9cb7b`, a `reporting` flag so the crash screen dying does not rebirth again) is the same bug class this fork fixed in 3.1.1 with a rate-limited restart budget — ours is already in and strictly stronger, nothing to port. Of v2.0.5/v2.0.6's feature list, per-group routing with subscription import, AmneziaWG WARP and the auto-selector work are already present here; DNS-tunnel outbound types are the one gap the core bump opens (UI work, queued)

#### 3.3.1-pre.14

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one is the review round over the whole branch: three parallel reviews covered the Kotlin host and the FFI boundary, the Dart data layer and its tests, and the UI-kit rename plus the tooling. No feature change.

The kernel lifecycle is the one that mattered. A reload that arrived while a start was still unwinding used to tear down the instance that start was about to produce and then silently do nothing — the dashboard said Started, the tunnel was dead, and no heartbeat would ever notice (the stop had turned the heartbeat off). Three findings shared that root:

* Lifecycle commands (`start` / `stop` / `reload`) now run **one at a time** through a serialized chain in `KernelService`: a command that lands while another unwinds waits for it and re-validates the world when its turn comes, so a stop behind a start still stops, a reload behind a start restarts the live instance, and a reload behind a stop does not pull the tunnel back up. A double start while the core runs is a no-op instead of overwriting the instance handle (which orphaned the live core inside the worker). A delayed heartbeat recovery compares the epoch it recorded when the core was lost against the current one, so a stop-and-restart by the user while the backoff sleeps cancels the recovery instead of reloading a tunnel the user just brought up. Four new tests pin the sequence
* The route-profile source had the same shape of bug on the data side: two concurrent first reads (two route screens opening at once) each ran the attach, and the loser's SQLite connection was cached over and never closed. The attach is now memoized into one in-flight future every caller joins. A reader that fails mid-read is closed and demoted to the channel for the rest of the run (SQL cannot heal inside a process), instead of staying cached and throwing on every read
* `kernel_worker` no longer leaks the spawned isolate when startup times out (it keeps the handle now and kills it, closing the events port), and the per-domain address iterator is released explicitly like every other temporary wrapper in the FFI layer
* The outbound picker on the rule editor reports a failed `groupNodes` through the box instead of dying as an uncaught async error

Three gates or sources were quietly broken:

* The **ip-api.com quality source** was switched to `https://` in the governance round — but the free endpoint answers 403 with "SSL unavailable for this endpoint" (verified live), so the source has been dead since, hedging away a request in the first wave on every lookup. It is back on `http://` with a comment that states the trade (the egress lookup's ip-api provider already makes the same one; the reply carries no secret), and the comment that claimed it "may refuse" and sat "in the last wave" — both false — is gone
* **`prism_drift.py` check mode now fails closed**: an emptied or mis-counted baseline manifest used to make every category zero and pass CI. It validates `files` is non-empty, `file_count` matches, and the commit is recorded, and a new `--expect-diverged banner.dart` turns the budget check into an identity check — a second patched file traded for banner.dart no longer fits under `--max-diverged 1`
* **`release.yml`'s tag dedup classifies `git ls-remote`'s exit codes**: 2 = free (proceed), 0 = exists (refuse), anything else retries three times and refuses to publish — a TLS blip used to read as "tag is free" and a re-dispatch could have clobbered a live release

Smaller honesties: the egress card's "last checked" reports when the answer was actually measured (a served-from-cache or failure-path answer used to be stamped "just now"); the notification template renders placeholders in one pass, so a profile name containing `{up}` can no longer be eaten by the rate substitution; `CONTRIBUTING.md`'s local coverage gate matches CI's `--min 40`; and the changelog's preview-coexistence sentence now describes what actually happens instead of contradicting itself.

Still open by decision: a Flutter-engine death leaves the Dart-owned core unowned (the widget's stop button cannot close it until the process dies — adopting the numeric handle into the host is the fix and changes a contract, so it wants its own round), `resolveDomains` on a stale handle after a stop leans on the Go side's panic guards being total, and the vendored AAR's view channels (`io.flrone/ghostty|openconnect|terminal`) have no in-repo counterpart to audit — an AAR string scan in CI is the answer when it lands.

#### 3.3.1-pre.13

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one fixes the notification buttons dialog that pre.12 shipped broken, and turns the notification text into something the user writes.

* The **notification buttons** dialog no longer crashes on open. The in-house `AlertDialog` renders its body on a `Surface`, not a `Material`, so `CheckboxListTile`'s `ListTile` reached `Material.of(context)!` and threw "Null check operator used on a null value" (release builds skip the `debugCheckHasMaterial` assert, so it surfaced as that null check rather than the assert message). The picker's body is now wrapped in a transparent `Material`
* The General page gains a **Show proxy speed** switch (`showProxySpeed`, default on). Off hides the proxy rate line; the cumulative total under it stays governed by **Show traffic total**, so the notification can be title-only, title + total, or title + rate
* The title prefix becomes a **title template** (`notificationTitleTemplate`): `{title}` is the profile name (or "Switching…") and everything else is literal, so `🚀 {title}` reads `🚀 Tokyo 01`. An existing `notificationTitlePrefix` is folded in on read as `<prefix> {title}`, so upgrading users keep their prefix without re-entering it
* A new **notification content template** (`notificationContentTemplate`) replaces the built-in speed line when set. Placeholders: `{title}`, `{up}`, `{down}`, `{directUp}`, `{directDown}`, `{totalUp}`, `{totalDown}`; a multi-line template uses the expanded (BigText) style. Empty keeps the built-in line and the switches above, so the two ways of shaping the body never fight
* Both templates and the switch ride the same `settings.set` channel as the other notification rows, apply on the service's next update (no restart badge), and are covered by the settings audit, the i18n gate (zh entries included) and widget tests

#### 3.3.1-pre.12

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. This one is the structure-audit round: the follow-ups the link-by-link review of the #19 data path asked for, with no feature change. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open — it now has a data-layer section with the exact commands.

The review found three structural risks (a schema gate that only compared version numbers, a versionCode scheme previews can never come back from, and SQLite reads on the UI isolate) and a tail of smaller ones. This lands the ones that did not need a device in the loop, plus the notification customisation round:

* The service notification gains three customisation rows on the General page: a **title prefix** (`notificationTitlePrefix`, prepended to every title — profile name and "Switching…" alike, empty = off), a **cumulative traffic switch** (`showTrafficTotal`, the up/down total under the rate line), and a **button picker** (`notificationActions`) — the five buttons (stop / previous / next / switch / reset) were already stored and read by the service but had no UI to change them; the picker shows the first three of the enabled ones in the host's fixed order, and an empty selection means no buttons. All three apply on the service's next notification update, so none raises the restart badge; all three ride the same `settings.set` channel and are covered by the settings audit and the i18n gate (zh entries included)
* `schema_audit.py` now parses Room's exported schema JSON and column-checks every SELECT in `flutter/lib/data/*_dao.dart` — a migration that renames or drops a column the SQL mentions by name fails the push instead of dying silently behind the channel fallback (previously only the version number was compared, and the version staying at 19 was exactly the case nobody would catch)
* Preview tags are capped at `-pre.998` in `release.yml`: 999 is the stable slot, and a `-pre.999` would have built the same versionCode as the stable release of that version; README now states the one-way rule (a preview never installs over the stable release it belongs to — `INSTALL_FAILED_VERSION_DOWNGRADE` by design)
* `data.path` no longer opens (and migrates) Room's database on the main thread — a new `respondIo` wrapper runs the block on `Dispatchers.IO` and replies on the main thread; `settings.get` moves with it (a cold read loads its JSON document from disk)
* A failed SQLite attach is now classified: a schema version mismatch is permanent for this run, while a cold-start `data.path` race or a locked file is retried up to three reads and gets a fresh budget every time the app resumes; `invalidate()` re-attaches from scratch for flows that replace the database file
* The read connection's `busy_timeout` drops from 2 s to 250 ms: until the connection moves to a DB isolate, that wait runs on the UI isolate, and anything longer falls back to the channel — which answers off the main thread anyway
* `readOnly` now defaults to true in both `openAt` and `openDatabase` (every production caller already passed it; only the defaults and one comment disagreed), the speed-test defaults are `https://` (both endpoints verified to serve TLS), and `TrustAllManager` carries the rule that every call site stays behind `net_insecure`
* The coverage gate can hold per-directory floors (`--min-dir lib/data:NN`) and prints a per-directory report; the locale audit runs on every push as a non-blocking report (885 known gaps, now visible instead of invisible)
* `docs/device-checklist.md` gains the data-layer section: overwrite-install failure codes, post-migration column drift, WAL concurrency and pulling the database off a debug package to confirm `PRAGMA user_version`
* New widget tests cover the three notification rows: the switch and the prefix write through `settings.set` without the restart badge, and the button picker saves in the host's fixed order regardless of the order the checkboxes were touched in

`BuildConfig.VERSION_CODE` was also re-checked statically: the updater filters candidates by version name first (`Semver.compare(version, installed) > 0`), so a device on this preview is never offered 3.3.0 regardless of how AGP fills the code. Still open, by choice: the DB isolate migration (the review's P0-1 — it waits for real-device numbers from the checklist above), the one cleartext IP probe source (`http://ip-api.com/json`, a user decision), and the missing `10.json` schema export (pre-dates the repository).

#### 3.3.1-pre.11

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one starts reading route profiles straight from Room over `dart:ffi`, with a transparent fallback to the existing channel.

The data layer had a `GroupsDao` but no route-profile access, while `RouteProfilesPage` still read through `routes.list`. This adds a `RouteProfilesDao` that reproduces the host's `list()` in SQL, and one `RouteProfilesSource` entry point: prefer a read-only SQLite connection at the path returned by `data.path`, and fall back to `routes.list` on any failure so the page never sees an error.

* `route_profiles` left-joined to `route_rules` for `ruleCount` / `simpleRuleCount`, and `current_route_id` decoded from `settings.value`; the wire shape matches `BboxRoutes.list()` field for field, so the fallback is invisible to the UI
* Read-only `DataLayer.attach`, a schema-version check, and total fallback — including an empty `route_profiles` table, which the host would otherwise seed on read
* `BoxController` owns the connection and closes it on dispose; `data.path` is wired on both the Dart and Kotlin sides
* The `NOT WIRED` comments, `docs/bbox-bridge.md` and the `3.3.1-pre.1` changelog note now describe the real state
* New DAO, source and fallback unit tests. CI is green end to end: `flutter analyze --fatal-infos`, `flutter test --coverage`, the coverage floor, Kotlin unit tests and the debug build, AAR API scan and cgo preamble checks. Physical-device checks — WAL concurrency with Room, the `data.path` version and migrated column names — remain open

#### 3.3.1-pre.10

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one lands the code review's fixes — the failed start, the hand-over timing and the blocking DNS lookup — with tests for the parts that had none.

A review of `main..feat/ffi` found two problems worth blocking on and six worth fixing. A failed core start left the notification claiming a tunnel that was not there, and one domain lookup could freeze the driver's one-second heartbeat for up to ten seconds. Both are fixed, along with the handshake timing around them and the loose ends the review listed.

* A failed core start now stops the foreground service too, and a hand-over that cannot become ready is rolled back to the bridge — no more "Connected" with nothing behind it
* Domain lookups run on their own short-lived isolate instead of the heartbeat, capped at one batch; status snapshots, loss detection and reloads no longer queue behind a slow name
* The hand-over polls a read-only service state instead of guessing one second, a refused VPN fails fast rather than waiting for a slow config build, and overlapping rate pushes are dropped
* The speed-test screen labels the cleartext lookup source and the two options that currently fall back; an operator name without an AS number is no longer truncated
* Tests cover the whole handshake path (8 Dart) and the new IP parsers (10 Kotlin). 326 Flutter tests, every CI audit and `flutter analyze` are green

#### 3.3.1-pre.9

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one stops computing memory and asks Android, and fixes two things behind the slow IP card.

The memory card went through three arithmetics, and each one was wrong for the same reason: the core's figure is the heap the Go runtime has *mapped*, not a share of what the process has resident. On a 286 MB process it read 319 MB, so any sum built on it produced a part larger than the whole.

* The panel now shows what `Debug.MemoryInfo` reports and does no arithmetic of its own: the process total, and its split by allocator — the app's heap, native allocations (the core runs there), and the rest. The four add up because the platform produced them
* The IP card was held for 48 seconds by one source whose name did not resolve: `Dns.SYSTEM` blocks inside `getaddrinfo` and nothing can interrupt it, while the probe waits for its children. Lookups now have a two-second deadline
* "Lookup provider" in the speed-test screen was written to `exit_lookup_provider` and read by nobody. The chosen provider now goes to the front of the race; ip-api, ipapi.co and freeipapi gained parsers

#### 3.3.1-pre.8

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one makes the memory card add up, and stops the IP card from waiting on a source that is not answering.

The memory card read 327.2 MB total on a 286.1 MB process, with a 319.2 MB core. The core's figure is what the Go runtime has *mapped*, not what is resident — different quantities, and the mapped one can exceed RSS. Using it as a share of the process produced a part larger than the whole.

* The process is the headline again, split into the app's heap, the core's share capped at what is left, and the rest (native allocations, graphics, shared pages). Every figure adds up, and no part can exceed the whole
* The IP card waited 3.5 s for the preferred source before a fallback was allowed to win, even though the fallbacks had already replied — 3.5 s of skeleton on every connect. The preferred source now has 1.2 s, and the whole probe 5 s
* A resolved address is cached for five minutes instead of thirty seconds. A route change still forces a fresh probe, so the previous exit's address is never shown

#### 3.3.1-pre.7

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one puts the memory card back on the arithmetic it started with.

pre.5 made the headline the process RSS and pre.6 made `app` the process minus the core, so the card read 283.3 MB for an app whose own heap is 13.7 MB. RSS is the whole process — ART heap, native allocations, the graphics driver, the Go heap, shared pages — and none of that is "memory this app uses" to the reader.

* The headline is `app + core` again: the ART heap plus the core's own heap
* What pre.6 added stays: the core's figure comes from the driver's status feed, not from an HTTP call to an API that is off by default
* The caption now says where the rest of the process goes, so a small total above a large RSS row reads as two different questions instead of a contradiction
* A core that reports nothing still reads as unknown rather than 0 B

#### 3.3.1-pre.6

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one is about where the core's memory figure comes from.

The core's share was read over HTTP, from the clash API. That API is off by default — `core_box_clash_api` starts at `-9090` — so the call spent a five-second timeout on an IO thread every two seconds and came back empty, which the panel then had to print as zero or unknown.

The core has been reporting its own heap all along, in the status snapshot that already carries the rates, the totals and the goroutine count. In FFI mode the driver is the only side holding the instance handle, so the channel cannot ask it; Dart can, and now does:

* `core` in the memory event is the driver's own figure, and `app` is the process minus it
* The bridge no longer calls the clash API in FFI mode — it was asking a question the driver answers every second, more slowly
* The HTTP path stays for the case without a driver, where there is nothing else to ask

#### 3.3.1-pre.5

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one is about the memory panel's arithmetic.

The panel built its headline out of two numbers: the app's ART heap and the core's own figure. On a 283.3 MB process the heap is 13.7 MB, so it announced a 13.7 MB total one row above a row that said 283.3 MB, and drew a bar claiming the app held a twentieth of what it did.

* The headline is the process now — the figure the RSS row states, and what "memory" means to the reader
* `app` is the process minus the core's share, so the parts still add up to the total instead of counting the core twice
* A core whose API is off reports nothing; that share now reads as unknown rather than "0 B", and the caption says it stays inside the process figure

#### 3.3.1-pre.4

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one is about how long the tunnel takes to come up.

Tapping connect used to run the two halves one after the other: Android brought the service up, and only then did Dart build the config. They have nothing to say to each other until the core asks for the tun, so they now run at the same time — the service's process start, notification and receiver registration are spent while the config is being built instead of in front of it. The screen is also told the tunnel is up the moment the core is, rather than after the running-config facts have been written to the store.

* `service.start` and `config.build` are issued together and awaited together; a failure in either still ends the start with nothing left running
* The `core started in` line now carries the split (`service`, `config`, `instance`, `start`) so the next round has numbers instead of a total
* The sing-box dashboard is unpacked at app start instead of at the first connect. It is 46 files out of the APK, once per install, and it used to sit inside `config.build` — on the one path the user is watching. `install()` is now synchronized, so the start that overlaps the prewarm cannot unpack into the same directory
* The wait for the live `VpnService` polls every 10 ms instead of 50 ms; the service registers itself in the first line of `startProxy`, so the poll was mostly measuring its own interval

#### 3.3.1-pre.3

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one corrects pre.2.

pre.2 stopped the service's zeros from overwriting the driver's figures, but it did so for every dashboard event — including the driver's own. Both feeds reach the same handler, so the merge kept the *previous* values and, once connected, nothing on the home cards moved again: no start time, no totals, no rates.

* The two feeds are told apart where they are subscribed: events from the kernel service are marked as the driver's and applied as-is, and only the channel's copy is merged
* A regression test drives both feeds through the same handler — the driver's numbers land, the service's zeros do not, and the mode still comes from the channel

#### 3.3.1-pre.2

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one is about the home cards' figures.

In FFI mode the service keeps running — it holds the tun and the notification — but it no longer owns a box. Its meter has no `TrafficUpdater`, so every number it reports is zero, and the bridge was still pushing that dashboard and a rate sample once a second. Dart's copy therefore alternated between the driver's snapshot and the service's zeros: every figure on the home cards flipped twice a second, and the sparkline sampled both values.

* The dashboard keeps the driver's fields while it owns the core — status, started time, both totals, connections, memory and goroutines — and still takes the mode, the selected profile and the system proxy from the channel, which is what persists them. A dashboard that merges back to the same map no longer notifies the UI at all
* The channel's rate sample is dropped while the driver runs, and the bridge no longer sends it in the first place

#### 3.3.1-pre.1

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.3.0. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one starts moving the data plane off the channel.

The bridge was the only way Dart could reach the database. The first table no longer needs it:

* **`groups` is read over `dart:ffi`.** `sager_net.db` is already opened `WRITE_AHEAD_LOGGING` — the app says so, and names the reason: a reader in one process running while the other writes. A connection in the Dart isolate therefore reads the same file without inventing a protocol between the two sides. The library is the platform's own `libsqlite3.so`, not sqflite, because this module's AAR cannot register a plugin: `registerScannerPlugin` exists precisely because the generated registrant is loaded by reflection and a failure there is swallowed
* **`data.path` is the one call left on the channel.** Dart cannot derive `/data/data/<pkg>/databases` without a package name it does not have. The host answers with the path and the schema version Room actually opened at, read from the file rather than the annotation — a downgrade makes those two disagree
* **`schema_audit.py` runs on every push.** A version bump on one side alone still compiles and still queries; it just reads the wrong column, silently
* **Every failure falls back.** `DataLayer.attach` returns null when the library, the path or the schema is not what it expects, and the screen keeps using the channel instead of going blank

The driver also regained what the service used to do while it owned the core:

* Running-config facts (`runningProfiles` / `runningRouteId`). Without them a node a running chain still uses could be deleted, and a group's routing change never triggered the reload that applies it
* Domain resolution for the diagnostics page, which had been answering "not running" on a live tunnel because it read a field only the gomobile start path fills
* The Wi-Fi monitor and its `wifi.state` events, so a rule that only applies on one SSID takes effect when the network changes
* The notification speed line, which `TrafficLooper` never filled in FFI mode
* The service-first race: a `START_STICKY` service that came up before Dart had already built a box of its own, and two boxes on one tun fight over the descriptor

The auto-selector panel now says the kernel holds the runtime instead of reporting "not running", and the widget speed is pushed from the same main-thread coroutine as the notification.

Writes and the other five tables stay on the channel until a device agrees with this one.

> **Correction (2026-11-07):** the four bullets above described the target slice, not a live path — at this release
> `DataLayer.attach` had no production caller, `data.path` was never invoked from Dart, and the source was marked
> `STATUS: NOT WIRED`. The first table actually wired is `route_profiles` (#19), read over `dart:ffi` with a full
> `routes.list` fallback; `groups` remains the un-wired slice. See `docs/bbox-bridge.md` for the current state.
> This note corrects the record; it is not a new build.

#### 3.3.0

The first stable release since 3.2.25. Previews pre.1–pre.13 were the test bed; the code here is the same, with the release notes written for people who do not read commit logs.

* **DNS resolves through the tunnel.** `dns.resolve` asks the running core instead of the system resolver, so a domain is answered the way the proxy would answer it
* **Scanning works again.** The camera preview no longer sits on a black rectangle: the host asks for the permission first, the screen says why a start failed, a payload that stops changing is completed instead of hanging, and the scanner plugin is registered on the engine so its channel exists at all
* **Startup is lighter.** The node catalog is no longer shipped and rebuilt on every start, and a type is named once instead of once per node
* **The memory panel tells the truth.** Process RSS is the process's own PSS; the ART heap rows moved out of the Core section, where they were being divided by the core's few megabytes and printing 1600%; the headline is what the process holds, not the heap ceiling
* Prism UI drift detection, the Flrone identifier unification and the Bettbox runtime guards that shipped through the previews are all included

3.2.x installs receive this through the in-app updater: `throne-update.json` is published alongside the APKs.

#### 3.3.0-pre.13

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.2.25. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one is about the memory panel's numbers.

The memory panel was printing four figures that were not what their labels said:

* `rss` carried the core's `inuse`, so "Process RSS" showed the core's few megabytes instead of the process's resident size. It now comes from `Debug.MemoryInfo.totalPss`, which counts a shared page once
* The details page divided the ART heap figures by the core's `inuse`, printing 1600% and 4000%. Those rows moved to the App section, where they belong, and the Core section now shows the one number the core actually reports
* `heapIdle` was `maxMemory - totalMemory` — headroom never allocated — not the idle part of the heap
* `stack`, `runtimeOther` and `goroutines` were hard-coded zeros with no source behind them, and are gone
* `running` and `remote` were never sent, so the release-memory button could not appear at all

The headline figure is now `app + core`, the memory the process holds, instead of the ART heap ceiling reading as if it were current use.

#### 3.3.0-pre.6

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.2.25. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. Scanner plugin registration.

`MissingPluginException(No implementation found for method state on channel dev.steenbakker.mobile_scanner/scanner/method)` is what the scan screen reported on a device. The channel only exists after `MobileScannerPlugin.onAttachedToActivity`, so the plugin has to be on the engine **and** attached to the activity; Flutter finds the module AAR's `GeneratedPluginRegistrant` by reflection and swallows a failure there (one warning, then nothing), which is why the screen showed a black preview instead of an error.

* The activity now registers the scanner plugin explicitly after `super.configureFlutterEngine`. The engine keys plugins by class, so this is a no-op when the registrant already ran, and it is what creates the channel when it did not
* If the plugin class is missing from the build at all, one line is logged (`scanner: … is not in this build`) instead of the failure disappearing into a warning
* Release builds keep `io.flutter.plugins.**` and the plugin's package, so shrinking cannot remove either side of that reflection
* The permission-first start and the on-screen reason from pre.5 stay: with the channel present, a denied permission now says so instead of leaving a black rectangle

Both AARs were checked locally: the module POM lists `dev.steenbakker.mobile_scanner:mobile_scanner_release:1.0`, the plugin AAR contains `MobileScannerPlugin.class` and the module AAR contains `io/flutter/plugins/GeneratedPluginRegistrant.class` — so packaging is right and the missing piece was registration at runtime.

#### 3.3.0-pre.5

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.2.25. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one is about the black camera preview.

The scan screen no longer sits on a black rectangle without saying why:

* The camera is started by the screen itself, **after the host has answered the camera permission** (`permissions.camera`, a `RequestPermission` launcher on the activity). mobile_scanner asks too, but its request only completes when the host forwards the permission result — a request that is never answered leaves `MobileScanner` on its black placeholder with `error == null`, which is exactly the "scan does nothing" symptom
* The preview area now reports state: a spinner while the camera starts, the plugin's own exception or the denial message when it fails, and after five seconds a hint to check the camera permission in the system settings plus a retry button
* A denied permission says so instead of leaving a black box

If the preview is still black after this, the message on screen names the cause (permission, or the plugin's exception text), which is the same thing `adb logcat | grep -iE "mobile_scanner|CameraX"` would tell us.

#### 3.3.0-pre.4

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.2.25. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This one fixes QR import.

Scan import could hang forever on a code whose text is not a URL, a JSON object or a share link:

* The scan screen assembles the frames of one QR and asks the bridge when the payload is complete. That decision only recognised a handful of prefixes — `http(s)://`, `{`, `sing-box://`, a share link — so a **base64 subscription** or a YAML document never completed: the screen sat at "0 / 1" while the camera's repeated frames were appended to the buffer over and over
* The assembly now also treats "this frame added nothing" as completion — a symbol that stopped changing is complete, whatever its text looks like — and a frame the buffer already holds is not appended again (the camera's A,B,A,B cycle used to build "ABAB")
* A payload that fails to import is no longer retried on every camera frame, which only flashed the same error; the same code retries after a short pause, a different one immediately

`BboxScanChunksTest` covers the link and URL shapes, the base64 case, multi-frame order and the session reset. If a **share link or subscription URL** still fails to import after this, the cause is the camera rather than the assembly — `adb logcat | grep -iE "mobile_scanner|CameraX"` says which.

#### 3.3.0-pre.3

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.2.25. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. No screen changes: the catalog stops parsing every node's outbound JSON.

* `ProxyEntity.displayType()` reads a row's outbound JSON to name its type, and the catalog called it once per node — a 3000-node subscription parsed 3000 configs on every catalog rebuild, which happens at startup and after every subscription refresh. The label is a property of the outbound class, and the stored `type` selects that class, so one row per type now answers for all of them. `custom` is the exception (its label comes from its own subtype and config type) and is still resolved per row
* The display name now comes from the name column instead of `displayName()`, which parsed the JSON to answer what the column already holds. The parse stays for the rare row with an empty name, where the address is the only label
* A row whose outbound cannot be parsed now renders with its stored type. Before, one malformed row threw out of the mapping and the caller turned that into an **empty catalog** — every group disappeared
* `BboxCatalogTypeLabelsTest` pins the per-type cache and the `custom` exception

#### 3.3.0-pre.2

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.2.25. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. No screen gains a feature here: this is the memory pass over the bridge and the package cache.

Startup no longer carries the node catalog, and the one-second sample no longer rebuilds it:

* `ready` answers with **group counts** (`nodeCount`, and `timeouts` for the dashboard chip) instead of every node row. The Proxies screen asks for the rows with `groups.visible` and gives them back on close; the rule editor's outbound picker asks `groups.nodes` for names (id + tag) only. The rows cost **134 B per node** on the wire — 391 KiB at 3000 nodes, 652 KiB at 5000, 2.6 MiB at 20000 — and three copies were alive while they were built (Kotlin model, wire maps, Dart decode)
* The first event-pump emission repeated exactly what `ready` had just returned, so the first frame built and decoded the whole catalog twice. The pump now stays silent until `ready` answers, and seeds its comparison baselines from that answer
* The 1 Hz rates sample used to rebuild `profilesWire` + `groupsWire` and structurally compare them with the previous copy — once a second, for nothing. The catalog half now rebuilds only when `BboxBridge.catalogRevision` moves (a repository change, or a visibility toggle), and `wireKey` compares that revision instead of hashing every node
* `json()` / `rows()` no longer re-normalize what the channel boundary already normalized: arrival deep-copied the startup payload a second time
* Memory pressure now reaches Dart. `onTrimMemory` emits `memoryTrim` and the UI clears its decoded-image cache — ART's `gc`/`trimHeap` cannot collect Dart objects — and a low-RAM device gets a 24 MiB image budget instead of 50 MiB
* `PackageCache` builds its listing on first use instead of during `Application.onCreate`, and no longer asks for `GET_META_DATA` (nothing reads an app's meta-data bundle)

**Not in this pass:** the per-node wire compaction (tuple encoding or a typed Dart node model) and the catalog's per-node `displayType()` parse. Both only affect the Proxies screen now that the rows are lazy, and the parse cannot be dropped without changing the type labels the UI renders (`AnyTLS`, `Auto Selector`, `Chain Proxy`, a custom config's subtype).

Tests: `BboxGroupsWireTest` pins both payload shapes and the picker list, `platform_value_test` gains the no-second-copy guards, and the Flutter suite is 298 tests.

#### 3.3.0-pre.1

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.2.25. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open.

The first v3.3.0 capability is a diagnostics tool rather than a copied page: **domain resolution through the running tunnel**.

* **Settings → Diagnostics → Domain resolution** resolves a list of names (one per line, commas or spaces work too) inside the core process, through the running box's `dns-direct` transport. That pinning is the point: a kill switch blocks the OS resolver, and a running Tun answers it from fakeip, so asking Android would report the tunnel's own fake address back as the answer
* Without a running box the page says "connect first" instead of resolving against the phone's resolver and presenting that as the tunnel's answer. 32 domains per request, 16 at a time, 5 s each — the core's own limits
* The new `dnsResolve` capability is the one diagnostics entry that is on; the vendored quality and STUN pages stay switched off
* **Why not the "Network quality" page** the roadmap had queued: the pinned core (`36b6bc4`) and upstream `dev` (`a973efe`) both export only `StartURLTest` / `StartIPTest` / `StartSpeedTest` — there is no `NetworkQualityTest` to call, so the page's `quality.start` contract could only be answered by inventing numbers. The reconnaissance note in `docs/roadmap.md` is corrected, and the raw DNS editor that was the documented fallback already ships in the DNS settings page
* No core change, no new permission, no schema asset: one AIDL method (`resolveDomains`), one `:bg` resolver, one bridge object, one page. `DomainResolverTest`, `domain_resolve_test.dart` and the navigation render pass cover the wire contract
* This is the first preview of the 3.3.0 line and it carries everything from the 3.2.26 previews — the Bettbox runtime guards, the Flrone rename, and the Prism UI drift gate. The 3.2.26 previews were never promoted to a stable release, so 3.3.0 is the version that reaches users of 3.2.25

#### 3.2.26-pre.4

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.2.25. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. No app code changed: this preview corrects the Prism UI baseline that pre.3 pinned to the wrong commit and tightens the gate that guards it, so the APKs are otherwise equivalent to pre.3.

The pre.3 drift report measured the wrong thing, and this release fixes the measurement:

* The vendored `flutter/lib/ui` matches `chen08209/prism_ui` @ `946af6d` (2026-11-01) file for file, except for one patch. pre.3 pinned `63450c0` — two commits later — so upstream's own progress was reported as our drift, and three files that are simply older than the tip were labelled "intentional forks". `prism_upstream.lock.json` now records the vendoring commit and the reviewed upstream tip as separate fields, which keeps "we patched this" and "we are behind" from collapsing into one number
* Corrected, verified numbers: **144 identical / 1 patched / 18 local-only / 0 removed**. The one patch is `banner.dart`: a notice with no action no longer stands between a press and the page under it
* The two upstream commits since the snapshot (`e93fec1` list/animation fixes, `63450c0` floating-sheet corners) touch four files and are deliberately **not** taken here. `docs/prism-upstream.md` lists each file, what upstream changed, and why the sync is queued — including the fact that the vendored `keyed_animated_list.dart` predates `scrollCacheExtent` forwarding, so `dashboard.dart`'s argument is currently dropped
* The tool gains an `upstream` mode that compares a checkout against the baseline (deliberately kept out of CI, since it needs network and a clone), shader-key normalization so the vendored asset path stops counting as drift, and `--max-diverged`. CI now fails both on a dropped upstream file and on a second unrecorded patch, instead of only the former

#### 3.2.26-pre.3

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.2.25. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open. This preview carries no app-code changes — it validates the new upstream-drift tooling and CI gate; the APKs are otherwise equivalent to pre.2.

Prism UI is now tracked, not guessed:

* `tools/diagnostics/prism_drift.py` measures the vendored `flutter/lib/ui` against a **pinned upstream baseline** (`chen08209/prism_ui` @ `63450c0`, one commit past `v0.1.2`). The committed baseline manifest and lock file let CI run the check fully offline; it reports 138 identical / 7 diverged / 18 added / 0 removed, and fails the build only if an upstream file is dropped locally (never intended)
* `docs/prism-upstream.md` records *why* the kit is vendored instead of pulled from pub.dev, the disposition of every one of the 7 diverged files (4 intentional forks, 2 mechanical vendoring changes, 1 low-risk upstream fix — the `sheet.dart` floating-foot rounding — we have not taken), the 18 local-only extension files, and the sync policy (no auto-merge; re-baseline only on a deliberate pull)
* CI runs the drift check on every push and uploads the report as an artifact, so future drift is visible the moment it appears

#### 3.2.26-pre.2

> **Preview build for testing only.** Published as a GitHub prerelease with no `throne-update.json`; the in-app updater still offers 3.2.25. Install manually from Releases, and do not use it as a daily driver. CI is green, but the physical-device checklist (`docs/device-checklist.md`) is still open.

Naming unification: the project is now consistently **Flrone**.

* The Flutter module package `b_box_ui` becomes `flrone` (all Dart imports), its Android package and AAR coordinate `io.ericlee.bbox_ui` become `io.flrone.ui`, and the two bridge channels become `io.flrone/box` / `io.flrone/events` — both ends, the design docs and the contract audit stay in sync.
* Gradle's `rootProject.name`, APK filename prefixes and CI artifact names are now `Flrone-*` instead of `Throne-*`; the log-export header, READMEs and governance documents use Flrone alone.
* **Deliberately unchanged**: `applicationId` stays `com.throneflclash`, so this preview still installs over 3.2.x and keeps subscriptions and backups. The GitHub repository name and all URLs are unchanged. Upstream package names (`io.nekohasekai.sagernet.*`, `moe.matsuri.nb4a.*`), Kotlin class names, translated strings that name upstream formats (`Throne-Link`, `.thrbackup`, "Throne-only"), historical CHANGELOG sections and vendored manifests are not rewritten.
* Historical planning documents keep their original identifiers and now carry a note pointing at the current values.

#### 3.2.26-pre.1

> **Preview build for testing only.** It is published as a GitHub prerelease and deliberately does not write `throne-update.json`, so the in-app updater keeps offering 3.2.25. Install it manually from Releases; do not use it as a daily driver. It has passed CI but has not gone through the full physical-device checklist (`docs/device-checklist.md`).

Runtime work ported from Bettbox, all confined to the Dart layer:

* A tag-scoped `Debouncer` / `Throttler` now coalesces repeated bridge round-trips; subscription refreshes get bounded retry with a per-attempt timeout
* A visibility gate holds high-frequency rebuilds while the app is backgrounded and replays their aspects once on resume, instead of rebuilding the dashboard for every push the Kotlin side delivers off-screen
* Config edits have a validated path (`profileWriteGuarded`): JSON is checked before it reaches the core, the previous content is retained, and a rejected write rolls back. An `AtomicFileWriter` provides tmp-file/validate/rename semantics for future Dart-side file writes
* Startup/framework errors now surface in the same banner the bridge uses, and the decoded-image cache is capped at 50 MiB
* New unit and performance-budget tests cover the debounce, throttle, retry, refresh gate, validation, atomic write, rollback and large-payload normalization

Release plumbing, needed before a preview can be published safely:

* `release.yml` derives the `preview` channel and GitHub prerelease flag from a `-pre.<n>` version, feeds the matching build number into `android-build`, and refuses a tag whose base version disagrees with `nb4a.properties`
* `publish_release.sh` marks preview releases with `--prerelease`, keeping them off `releases/latest` and out of the self-update channel
* Previews published from a tag keep the normal package name, so installing one replaces the stable build (same signature); only the preview workflow's dispatch builds carry the separate debug package name, and only those install alongside. The signature is unchanged from 3.2.x throughout

Repository governance: multi-language README index, `SIGNING-POLICY.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, PR template, Dependabot config, issue-template config, rewritten `AUTHORS`, CI coverage and generated-model guards, and fixes to stale version/packaging claims in the planning docs.

Not included in this batch (deliberately): the application-id rename, removal of the dormant FFI subtree, `QUERY_ALL_PACKAGES` / targetSdk changes, telemetry, and the physical-device verification pass.

#### 3.2.25

* Local restore asks for the file instead of replaying whatever this process created last: `backup.open` opens the system picker, reads the selection, and accepts both the JSON envelope the local "Backup" entry writes and a `.thrbackup` container. Before, the local entry only returned a backup still held in memory, so after a restart it answered "No backup to restore" and the file the user saved could never be chosen
* Backing out of the picker now asks nothing further: it used to fall into the same "no backup" dialog, which read as a failure rather than a cancellation
* A subscription import or refresh drops repeated nodes inside the batch: the duplicate key is the desktop's (the JSON link without its tag), so one server listed under several remarks — or twice in one body — becomes one row. This is per batch only; duplicates already stored across updates remain the subscription's `removeDuplicates` option's job
* The "filtered out by name" line counts only the name filter again; deduplicated nodes are logged instead of inflating that number

#### 3.2.24

* The bridge drives the core again. `KernelService` no longer claims the service on start-up (`ffi.mode` stays off), so `BaseService` runs `ProxyInstance` itself: this is the path that kept the tunnel up before the FFI rewrite, restored here without deleting the FFI driver — it stays behind `kFfiDriverEnabled` for a later, device-verified return
* Nothing on the Dart side opens `libthrone.so` in bridge mode: the kernel log stream and the status events are no longer subscribed from the FFI message port, so the channel's `logs`/`rates` pushes are the only source and cannot be duplicated or raced by a second driver
* The start/stop/reload calls fall back to their channel branches (`service.start`, `service.stop`, `service.reload`, `state.setMode`, profile/group selection), which is what the UI already used before the FFI path existed
* The restart-loop fixes stay in place for the FFI path (alive probe, non-sticky error channel, bounded recovery) and the lifecycle breadcrumbs keep writing `[lifecycle]` / `[service]` lines, so a future switch back has the diagnostics it needs

#### 3.2.23

* The heartbeat stops killing a core that is running: a status read that failed was reported as an empty snapshot, which the driver read as "the kernel is gone" and answered by closing a tunnel that was carrying traffic. The read now answers an `alive` marker when it panics, and a new `throne_Instance_alive` asks the cheap question — is this box still started — before a miss is counted, so only a core that really stopped is restarted
* The exit probe no longer runs several five-source races at once: a state that changed faster than the answer started a new round per second (fifteen TLS connections and a fresh dispatcher each time) while the phone was already busy with the tunnel. Rounds are serialised and the second caller reads the cache the first filled
* The probe keeps one HTTP client per route instead of building and shutting one down on every check, and `invalidate()` drops the pooled sockets of the route that just changed
* A restart loop can now be read out of the log: the driver writes `[lifecycle]` lines (start, stop, reload with its reason and origin, heartbeat loss, start failure) and the service writes `[service] state -> …` on every transition into the same `core.log` the log screen shows — the core closing on its own left no trace of who asked for it

#### 3.2.22

* Fixes the service that restarted every few seconds and never stayed up. Two faults each closed a box that had just come up, and the recovery started it again
* The FFI error channel no longer keeps an old message: `throne_last_error` hands the text out once and clears it, `Instance.start` / `close` / the instance factories clear it on entry, and the once-a-second status reads keep their panics out of it. A single failure — even a panic inside a status poll nobody checks — used to fail every later start, and the failed start closed the box it had just opened
* The heartbeat no longer counts raw misses: a status only answers once the box is up, which takes seconds (tun, rule sets, xray assets), so three misses in three seconds read as a lost core. A miss now counts after a 12 s grace from the start and 8 s since the last good beat
* Automatic recovery is bounded and backs off: the first restart is immediate, then 10 s, then 30 s; after three attempts in a row that never held a minute the failure is reported to the UI instead of retried, and the lost event carries the kernel's own message so the reason is visible

#### 3.2.21

* The status card asks every IP source at once instead of trying three in sequence: the richest one (ipwho.is) gets 3.5 s on its own, the first fallback that answered takes over after that, and the whole probe gives up at 8 s — a blocked endpoint used to cost up to twelve seconds each
* Two reachable-where-it-matters sources join the list (uapis.cn, geojs.io), so a phone that cannot reach the international endpoints still shows its exit address; the card and the details screen now name the endpoint that actually answered rather than always claiming ipwho.is
* The probe closes the HTTP client it opened for each check; its dispatcher threads and pooled sockets used to outlive every request
* The network-speed sparkline is sampled once a second while the service runs, the way Bettbox's `tick1s` does: an idle tunnel scrolls to zero instead of freezing on its last peak, and a burst of pushes can no longer stretch the half-minute window
* Stopping the service clears both sparkline windows, the live rates and the totals, so the next session draws a curve of its own instead of continuing the previous one

#### 3.2.20

* Rebuilds the package on the current `main`, so the installable APKs match the branch you ship from: this release carries every 3.2.19 fix and nothing else that changes behaviour
* The only commit after 3.2.19 is a cleanup of the selection writes: `select()` and its awaitable twin carried the same body, so the "switch a running service to the new node" broadcast could drift between the two paths; both now call one `applySelection()` and one `postSelectionUpdate()`

#### 3.2.19

* Fixes the crash `type '_Map<Object?, Object?>' is not a subtype of type 'Map<String, dynamic>' in type cast`: `StandardMessageCodec` decodes native maps into `_Map<Object?, Object?>`, so every channel reply is now normalised recursively (`normalizePlatformValue` / `asStringKeyedMap`) instead of being cast, with `TypedData` payloads preserved
* Fixes `Bad state: configure tun interface: bridge: platform callback failed`, which had three separate causes: the FFI start path never registered `DataStore.vpnService` (it returns before `startProcesses()`), `service.start` replied before the service existed, and `throne_TunOptions_toJSON` panicked on the nil `TunPlatformOptions.HTTPProxy`
* `service.start` now waits for a live `VpnService` (8 s, then fails loudly) instead of posting an intent and returning, so Dart can no longer start the core before the tunnel owner exists
* `throne_TunOptions_toJSON` reads the HTTP proxy getters only when the option is enabled (they dereference a nil pointer otherwise); the panic used to empty the whole TUN spec, so `VpnService.Builder` failed with "End of input at character 0"
* Stopping the service releases the kernel's cached tun descriptor (`Core.stopTun()` in `killProcesses()` and `onDestroy()`); without it the second start reused a closed fd and skipped establishing `tun0` while the dashboard still said Running
* The outbound mode switch now sticks: `BboxKernel.setMode` refreshes the bridge state and `dashboardWire` reads the stored mode instead of its cached copy, so the chips no longer snap back to the previous choice after the per-second state push
* `openTun` failures are logged with their reason instead of returning a silent `-1`, and `tunSpecJson` reports `throne_last_error()` when the spec comes back empty
* Adds five regression tests (15 total) covering the service-start ordering, the disabled-proxy spec, the mode refresh and the tun descriptor release
* The Log screen no longer throws on a kernel line: the FFI path stamped `receivedAt` as an ISO string while the channel path pushes milliseconds, so the timeline formatter failed on every pushed record; both paths now share one unit, and kernel ids start at their own offset instead of colliding with the channel ids
* A failed start no longer orphans a native instance: `_startCore` releases the handle `createInstance` already created when `start` throws, `KernelWorker.dispose()` closes the instance it still holds before closing the port, and a new instance replaces (and releases) the previous one
* `reloadService` only restarts a core that is actually running, so reloading from the Stopped state no longer boots the kernel behind the user's back, and concurrent `initialize()` / start calls are serialised
* `KernelService` stops emitting into a closed `StreamController` after `dispose()`, and the dashboard clears `startedAt` when the status is Stopped instead of keeping a stale uptime
* The channel/FFI routing predicate is `kernel.ffiMode` rather than `ThroneKernel.isAvailable`: the latter is true as soon as the library loads, so a failed `initialize()` used to leave the whole control plane calling into a kernel service that was never created
* `ProxyInstance` builds its `TrafficLooper` under a lock and stops it before the box closes, so a start/stop burst can no longer leave an orphan looper writing to a closed engine, and the last traffic sample still reaches the UI
* `VpnService.conn` is `@Volatile` and the previous descriptor is closed when the tunnel is re-established; the old fd stayed open on every reconnect
* `BaseService` keeps its callback ids in a `ConcurrentHashMap` (binder callbacks arrive on several threads), and `SagerConnection` decodes the state with a bounds check instead of indexing `State.values()`
* `SubscriptionRefresh.startWhenStopped` re-checks the user's intent before starting the successor, so a manual stop during a subscription reload is no longer overridden a second later
* `BboxBridge.scheduleRefresh` records a pending request instead of dropping it when one is already running (the tail of a burst used to be lost), `requestEgress(force)` upgrades a running probe to a forced one, and `BboxEgress.invalidate()` clears the cached answer rather than only its timestamp
* `BboxCommands.watchTestSession` cancels its collector when a session ends without any proxy tested, and the profile / proxy selection calls are awaitable, so `profiles.select` and `groups.select` reply once the selection has landed instead of before it starts
* `SagerDatabase` runs its queries on a bounded pool instead of `GlobalScope.launch`, and `ThroneBoxBridge.setConnectionsVisible` drops its cached frame when the screen is hidden

#### 3.2.18

* Hardens the FFI kernel boundary: all 423 `throne_*` exports recover from Go panics instead of aborting the process, and `Dart_InitializeApiDL` failures return an error rather than panicking across cgo
* Fixes the handle leak: wrapper objects release handles explicitly (`release()`), a shared `Finalizer` is the GC fallback, `Instance.close()` drops its own handle, and `throne_handle_stats()` exposes live/created/released counters with a leak warning
* Moves every FFI call into one long-lived isolate (`kernel_worker.dart`): no `Isolate.run` per operation, no repeated `dlopen`, and the UI isolate never opens `libthrone.so`
* Replaces the eight-call-per-second status poll with one `throne_status_snapshot()` crossing that creates no handle; Go pushes a `status` event to the message port. Three failed heartbeats mark the core as lost and trigger one automatic restart
* Startup and worker failures now surface in the UI (`startupError` and error events) instead of hanging on the loading view or being swallowed by `debugPrint`
* `config.build` is id-free on both sides: `BboxKernel.buildStartOptions()` takes no parameter and ignores stale arguments, with the native DB as the single source of truth (ADR 0001)
* CI adds a three-way symbol audit (Go exports / both C headers / Dart lookups), FFI regression tests, cgo preamble `-Werror` checks, a settings audit, coverage upload and job timeouts; generated bindings are excluded from analysis instead of blanket-waived
* Release publishing is idempotent, retries GitHub API 5xx three times, preserves signed APKs as artifacts on failure, supports `v*` tag pushes, and documents manual recovery in `docs/release-runbook.md`
* Adds `docs/adr/0001-ffi-boundary.md` declaring the conservative FFI boundary: Kotlin owns the data plane, FFI owns the control plane

#### 3.2.17

* Fixes the FFI startup failure `profile 0 is gone`: `config.build` no longer receives a guessed profile id from the Flutter preference store (which holds UI settings only), and the native bridge resolves the selected node from `DataStore.selectedProxy` instead of looking up id 0
* The profile lookup now tolerates stale ids and B-box's group-shaped profile card ids, falls back to the first stored node when a fresh install has none selected, and reports a clear "no profile selected" message instead of a platform exception
* The FFI dashboard events take their `selectedProfileId` from the channel wire, so the selected profile name stays correct across starts and reloads
* Adds a regression test that fails if a non-positive id is sent to `config.build` again

#### 3.2.16

* Dart now drives the kernel directly: a generated `dart:ffi` binding layer (`tools/bindgen`, Bettbox's shape) replaces the method channel for kernel control, with events flowing back over `Dart_PostCObject` ports and the Android duties (VPN fd, `protect` / `resolverProcess`) crossing a tiny JNI shim (`android/core/`)
* The core shares the app's process — the `:bg` process split is gone, so the Flutter engine, Kotlin and the Go kernel run together with no AIDL or cross-process hops
* The VPN fd reaches the kernel the way the architecture describes: `VpnService` establishes the tunnel from the kernel's own computed `TunOptions`, then feeds the fd back with `Core.startTun(fd, TunInterface)`; a pre-fed fd from `throne_start_tun` is honoured first
* The kernel operation surface (service start / stop / reload, clash mode, outbound selection, WARP registration, status and traffic) runs over the FFI path when the rebuilt core is present, with the channel kept as fallback; profiles, routes and settings stay on the channel until their storage moves
* The Go binding patch is purely additive (`buildScript/core-patch`), so CI builds the patched core from any Throne checkout without upstream write access; the unpatched AAR still builds, the shim probing for the bridge symbols before linking

#### 3.2.15

* Removes the retired preference UI layer: 16 `res/xml` preference screens, the 6 preference classes that only those screens inflated, the 3 support classes that existed to drive them, and the matching ProGuard keep rules — Flutter has been the only settings surface since 3.0.0
* Removes 12 dead Kotlin files (the old traffic chart, connection FAB, QR share dialog, undo snackbar, always-on / OEM-background / app-shortcut helpers, save-document contract, RecyclerView layout managers, and the JSON schema completion / validation engine) and trims three files that were only partly dead, keeping the live parts: `SchemaStore`'s two schema roots, `WindowInsetsListeners`' app-bar inset chain, and `JsonRelaxations` minus its validator hookup
* Drops two unused Dart libraries (`input_limits`, `iterable`) and demotes `flutter_localizations` from a direct dependency — `material_ui` ships its own `GlobalMaterialLocalizations`, so the SDK package is only a transitive one now
* The README now describes the status card as it actually renders (emoji badge with location / carrier) and the Log screen as FlClash's rebuilt log view; the JSON editor entry no longer claims schema checking or completion, which left with the engine

#### 3.2.14

* Borrowing Bettbox's pending-buffer pattern, a burst of log, Logcat or connection events now shares a single rebuild: the state is current as soon as each event lands, but the UI is told once the 300 ms window closes instead of once per event
* The log tail keeps a fixed window of 512 records (Bettbox's `maxLogLength`) however long the screen stays open, so a long-running service cannot grow the list without bound
* Polling now stops when nobody can read it: the automatic-selector's 3-second status poll and the status card's 1-second runtime clock are both gated on the app being in the foreground and the page not being covered

#### 3.2.13

* The Log screen is now FlClash's own log view: a single export action, the empty state, a scrollbar that names the record at the thumb, and a list that stops following the newest line as soon as you scroll away from it
* Each record is split into what it actually says and where it came from: the level, uptime counter and subsystem prefix (`INFO[0001] inbound/tun[tun-in]:`) are parsed off, so the message reads on its own with the subsystem (`inbound/tun · tun-in`) beneath it, and tapping the level chip filters by it
* Following FlClash, the Log screen no longer carries this fork's extra controls: the level-filter menu, pause toggle, clear, crash-log export, Logcat switch and connection-reset folding are gone. Logcat remains available to the core, but the screen no longer shows it

#### 3.2.12

* The backend-to-UI path now mirrors Bettbox's architecture: a single typed `BoxEventBus` (with sealed `BoxMessageEvent` / `SubscriptionReportEvent` / `IntentAvailableEvent` / `BrowserCompleteEvent`) replaces the four ad-hoc event controllers, and listeners subscribe to the slice they care about
* Every scattered `call('method.name', ...)` string invocation across the pages is folded into a semantic facade (`box_api.dart`), grouped by domain as extensions on `BoxController`, so method names are checked at compile time and parameter shapes live in one place
* The event streams stay cached (repeated reads yield the same broadcast stream, as the old controllers did), and closing the controller now releases every event stream instead of all but the subscription reports

#### 3.2.11

* The VPN service now restarts itself when the system reclaims it under memory pressure (`START_STICKY`), so the proxy reconnects instead of dropping silently; a manual stop still ends the service for good
* The app answers Android memory pressure (`onTrimMemory` / `onLowMemory`) by hinting the ART runtime and trimming the heap back to the OS — Bettbox's background-GC strategy on Android, leaving the Go core's own allocator untouched
* The Log screen's follow-newest control moves to the toolbar as a highlighted auto-scroll toggle, matching Bettbox's log view

#### 3.2.10

* The status card's bottom row no longer overflows on a narrow display with large text: Run time joins Location and Operator as an equally flexible column, so all three shrink (with ellipsis) instead of spilling past the card edge
* A two-letter country code is no longer repeated as text in the Location column — the badge's regional-indicator emoji already shows it, so the location only carries a full country name and the city
* The Xray VLESS form gains Chinese labels for its Reality/TLS fields (Fingerprint, Use system CA, Pinned cert SHA256, Short ID, Authority, SpiderX)

#### 3.2.9

* The Settings → Core → Logging "Log level" (and "Xray log level") now actually takes effect. The level was gated behind a process restart (`Apply.AppRestart`), but the core already re-reads `log_level` and rebuilds the config on every reload, so it only needed `Apply.Reload`; both choices now also re-apply to a running core the moment you pick a new level instead of waiting for a stop/start
* The dashboard's status card borrows Bettbox's IP-detection display: a regional-indicator emoji stands in for the flag, a `country · city` location and an `ASN · ISP/operator` carrier sit beside the address, and the bottom row is now Run time / Location / Operator. The probe tries `ipwho.is` first (it returns country name, region, city, ISP and ASN over HTTPS); the existing `ip.sb` and `ipinfo.io` endpoints stay as fallbacks, and the detail sheet shows the new fields when the source supplies them. The `country_flags` dependency leaves the bundle with the SVG flags it drew

#### 3.2.8

* A single imported node no longer becomes a configuration of its own: it joins the shared "Default" group (the tab Throne's empty table starts with), so hand-imported `ss://` / `vmess://` / `vless://` nodes accumulate in one tab instead of one tab each. The editor's name renames the node, not the group
* The configuration list's "+" gains a "New node" entry: pick a protocol and the typed editor opens on a fresh node of that type — the manual entry Throne's per-protocol editors provide — and the node lands in the selected configuration (or the first one)
* The typed editor now covers Xray VLESS (`xrayvless`), whose document carries `protocol` + `streamSettings` instead of `type` + `transport`: the form reads `settings.address`/`port`/`id`/`flow` and the Xray network (TCP / WebSocket / HTTPUpgrade / gRPC / XHTTP / XDrive) with its TLS and Reality blocks. Multiplex stays on the Node tuning screen
* The proxy menu gains "Clear test results" and "Clear traffic statistics" for a configuration: the former drops the stored latency measurements, the latter zeroes the running core's live counters and the table, both behind the same confirm as delete (from ThroneForAndroid's profile menu)
* The dashboard's "System HTTP proxy" card is "Network takeover" now, matching FlClash's current card registry; the card set otherwise maps one-to-one onto FlClash's (status, network speed, outbound mode, profile, proxy groups, memory, intranet IP)

#### 3.2.7

* Sync ThroneForAndroid's VPN allow-bypass: while the VPN is up, apps may bind sockets to the underlying network themselves — FCM needs this for its push channel. Exposed as an "Allow VPN bypass" switch under TUN; the bridge key is `vpnAllowBypass`, kept apart from the `allowBypass` key the FlClash UI already uses for "bypass private ranges"

#### 3.2.6

* The About page credits `giturass/B-box` in the app itself: its bridge and Flutter-module setup is the migration approach this port follows, and until now the thanks lived only in the README. The entry sits with Source code / Core / FlClash interface and links to the project; a test pins the line so it cannot be dropped silently

#### 3.2.5

* Reverts 3.2.4's packaging experiment: `useLegacyPackaging = false` stores every native library uncompressed inside the APK so it can be loaded in place, and libthrone.so alone is 82 MB — the download doubled to 120 MB per ABI for a disk saving the extracted copy mostly paid back anyway. Native libraries are deflated in the APK and extracted at install again; do not update to 3.2.4 on a metered connection, its size advantage over 3.2.3 is negative. Everything else in 3.2.4 stands (R8's precise keeps, the Twemoji removal, the font subset, the WebP artwork, the debug-only GC, Jetifier off)

#### 3.2.4

* R8 finally shrinks the app: the keep rules now cover only what is actually reflective — the outbound types `OutboundFactory` instantiates by name and the preference classes the `res/xml` screens inflate by tag — instead of the whole `io.nekohasekai.sagernet` and `moe.matsuri.nb4a` packages. R8 full mode turns on with them, and crash records keep line numbers now
* Twemoji leaves the bundle: the emoji font hook is never wired (no `emojiFont` reaches the app's widget tree, and the font picker never offered the family), so its 1.4 MB were dead weight. JetBrainsMono is subset to the Latin, punctuation and box-drawing glyphs the code, reports and terminal surfaces actually use — 267 KB down to 71 KB
* Launcher, monochrome and TV banner artwork is WebP now (the About page's hero art with it); together with the fonts this is roughly 1.9 MB out of the source tree and most of it out of every APK
* Native libraries load from the APK instead of being extracted to `/data` at install time, so a second copy of the Flutter engine and the Go core no longer sits on the device's disk
* The dashboard's release-memory button no longer runs a full GC on release builds (a perceptible pause that bought nothing); debug builds keep the call for the button's sake
* Jetifier is off: nothing ships `com.android.support` artifacts any more, and the rewrite taxed every build for nothing
* `docs/toolchain-upgrade.md` schedules the dependency-pin cleanup (AGP to 8.9 and the CameraX unpin, Kotlin to 2.2 and the deletion of `-Xskip-metadata-version-check` and the version `force` block) as batches U1–U3, with the AAR API scan staying as the permanent gate

#### 3.2.3

* The TV banner carries the new mark as well: the painting's range sits on the paper tone where the crown used to be, and the "Throne" wordmark is left exactly as it was, pixel for pixel
* The status-bar and quick-settings glyph follows it: a three-peak silhouette traced from the same painting, kept solid rather than painted because the system tints it, with the summits rounded so it still reads at 24dp

#### 3.2.2

* The app's mark is a watercolour range now: three peaks in ink and gold on cream paper, in place of the green crown. Every launcher density carries it — a rounded square where a plain bitmap is still expected, and an adaptive icon whose layers hold the same painting, the paper tone as the background and the range inset a little so no mask cuts it; the monochrome layer is a silhouette traced from the ink, so themed icons follow the new brand too
* The About page wears the same painting in its hero, cropped to the icon's square, so the picture there is the picture on the home screen

#### 3.2.1

* The About page wears the app's own icon: the throne's crown on the white plate the launcher draws, cut from the launcher's own artwork at its native resolution. The old B-box cube leaves the bundle with it
* "Hide from recent tasks" works again: the switch had been left with nothing reading it when the fragment UI retired, so the task stayed in recents however it was set. The Flutter host applies the flag on resume and the moment the switch is flipped — the value arrives through the configuration store, so there is no wait for the next launch — and it keeps its own reference to the task, because an excluded task drops out of `getAppTasks` and that reference is the only way back once the switch is turned off

#### 3.2.0

* The interface moves onto prism, the UI layer FlClash's dev branch rebuilt on (`bb47f2cc`, v0.9.3): the vendored v0.9.2 widget set is replaced by prism_ui 0.1.2 — iOS-style press feedback, text selection with its own edit menu and loupe, sheets that snap, banners, tabs, sliders, checkboxes and text fields, all drawn from one seed colour
* Pages are built on prism's scaffold: the bar, its search and its overflow menus come from `PrismScaffold`/`ScaffoldBar`, and a page that filters by a record's labels now owns the keyword strip itself
* Transient messages are prism banners instead of Material snackbars; a notice carries no action and lets presses through, so a "Copied" banner no longer sits between a tap and the page
* Theme: prism's `ThemeData` carries the app's colour scheme (including pure black and the elevated dark surfaces); `MaterialApp` keeps a Material theme derived from the same accent and every page body sits on a transparent Material, so the Material-based forms, dialogs and animations still work while prism widgets read prism's theme
* Kept from the fork: page transitions through prism's `showExtend`, the JSON editor and its schema engine, the QR view, the settings rows and the app glyph set; `ListItem.input` still shows the stored value on its row and the example as the dialog's hint
* Dropped packages nothing referenced any more: `qr` (prism's QR matrix replaces it), `emoji_regex` and `animations`
* Tests and the pixel oracle were updated to the new theme and widget tree: `flutter analyze --fatal-infos` is clean and all 241 tests pass

#### 3.1.4

* The remote link field and the rule editor's inputs no longer pull up the system's password keyboard: Flutter maps `enableSuggestions: false` to Android's `TYPE_TEXT_VARIATION_VISIBLE_PASSWORD` (several IMEs ignore the plain no-suggestions flag), so the system classified them as password boxes, switched to its secure keyboard and took the clipboard away. Ordinary fields now keep suggestions on and only disable autocorrect; genuinely secret inputs (the obscured ones) still opt out
* Applies to every non-secret input, not just those two: profile URL, routing profile name/URL/endpoint ids, rule name and every domain/keyword/CIDR/port/process row, subscription and group settings, WebDAV address and account, node tuning, request header editors, the terminal prompt and both code editors
* New `input_keyboard_test` pins the contract: a field that is not obscured may not disable suggestions or ask for the visible-password keyboard
* Every URL field asks for the ordinary text keyboard instead of the URL one: the remote link, the routing profile's remote URL, the WebDAV address, subscription URLs, the test/connectivity URLs, DNS server entries and the generic input dialog. The `/` and `.com` shortcut keys go away with it, but so does the URI-specific IME layout that some ROMs refuse to paste into

#### 3.1.3

* The home badge shows the exit's region as its vector flag again instead of the two-letter code, cropped to the animated clover; a code the flag set does not know still falls back to its text, and an unknown exit keeps the proxy glyph
* With the service stopped the card now reports the address the phone itself appears as: the egress probe skips the mixed inbound (nothing answers it while the core is down) and asks over the device's own connection, so the card no longer sits on "—" until the tunnel starts
* The tunnel answer and the direct answer keep separate caches and both are invalidated on start and stop, so the card cannot show the previous session's exit after a reconnect
* A direct answer skips the IP quality lookup — grading the phone's uplink says nothing about an exit — while the address, region and carrier still show
* Tapping the badge or a route change asks the bridge for a fresh probe instead of the 30-second cache, so switching networks while stopped updates the address immediately
* country_flags returns to the build for the flag set

#### 3.1.2

* The status badge and the IP card are back to their first version: the exit's country code on the clover and a tap that re-checks the IP, with no flag icon and none of the crop/rotation machinery behind it
* Editing a route rule no longer opens a white screen: the editor read reject_method (a scalar field) as a list, and the cast error kept the whole page from building, so a rule could not be edited or added
* country_flags leaves the build: its .si flag assets were 34 MB that nothing referenced any more

#### 3.1.1

* Log export works again: the redaction patterns used nested possessive quantifiers that the desktop JVM accepts but Android's ICU regex engine rejects while the class initializes, so "Export" crashed the app on every device (and the crash screen crashed again, restarting in a loop). Every pattern is now plain, compiled defensively one by one, and each redaction pass is contained: a rule that cannot compile or apply leaves the line alone instead of taking the export down
* Crash restarts are rate-limited: a crash raised by the startup path itself no longer restarts into the same crash forever — after two restarts inside a minute the app stays down and the record on disk is what gets reported
* The crash-report screen catches Throwable, not Exception, so an `ExceptionInInitializerError` (the type this bug raised) can no longer escape the screen that exists to report crashes
* A unit test now runs every pattern over realistic log lines and guards the redactor against possessive quantifiers

#### 3.1.0

* The hardening round ships here (its code rode the 3.0.13 build): the core log folds the sing-box lazy handshake's known-benign connection-reset errors behind a counting chip, a long single-line log line wraps inside its tile instead of overflowing it, tapping a record copies it
* Uncaught app-layer exceptions keep a durable seven-day record beside the rotating core.log, exported as one redacted file from the logs page
* CI gates: the Dart/Kotlin channel contract is audited on every push, the freshly built Flutter AAR is scanned for APIs the pinned kotlin-stdlib/coroutines do not provide, and `flutter analyze --fatal-infos` keeps the module at zero lint debt (167 stale infos cleared)
* The update integrity gate is a plain JVM surface with rejection tests; `docs/device-checklist.md` documents the pre-release device gate
* The README and design docs describe this distribution on its own terms; `docs/roadmap.md` carries the development plan

#### 3.0.13

* The home status card keeps its vector country flag upright while its crop follows the animated clover, filling the badge throughout a refresh
* Flag/code switching remains accessible during a lookup, unknown country codes offer a working retry, and the keyboard focus ring stays visible above the flag
* Includes the logcat main-thread blocking, stale-buffer and clear/cancellation fixes from 3.0.12, plus the IP-probe session and log-export fixes from 3.0.10–3.0.12
* Adds regression coverage for native probe cancellation, concurrent first requests, delayed session opening, late replies, animated flag clipping and focus visibility; logcat thread assertions now also accept the coroutine debug suffix used by Gradle CI

#### 3.0.12

* Closing an IP-probe session now cancels its in-flight lookups and releases their threads and tunnel connections instead of stranding them; a lookup that races the close reports a clean cancellation, and a call landing after the activity closed answers "cancelled" instead of a stale failure
* Backing out of a log-save dialog is neither an export nor a failure — the logs page stays silent; the export button disables while a save is in flight or the list is empty, and a failed save no longer loses the visible logs
* The logcat tail is rebuilt as a cancellable reader with a mutex-guarded, time-boxed clear and injectable process spawning, making its lifecycle unit-testable on the JVM

#### 3.0.11

* The status card's IP quality lookup no longer fails on a freshly read IP: the probe transport opens its native session before its first request, and the bridge answers a get for a session nobody opened by creating one instead of throwing "No probe session is open" — a quality-cache miss used to fail every quality source and spam that warning
* Closing a probe session now releases its executor threads and the connections pooled through the tunnel instead of leaving them to the garbage collector

#### 3.0.10

* Logcat clear no longer forks and waits for `logcat -c` on the main thread: the clear runs on the IO dispatcher, so tapping Clear cannot stall the interface while the child process runs
* A log export whose target stream cannot be opened now reports "导出失败" instead of confirming an export that wrote nothing

#### 3.0.9

* The status badge's vector flag fills the clover without letterboxing: country_flags paints the .si flag with BoxFit.cover in the 48x48 badge box and the clover clip trims the overflow; a widget-tree test now locks that vector path in
* Log export shows a confirmation ("已导出") or failure ("导出失败") message instead of being silent
* Logcat entries on Android 10+ preserve the tag (e.g., "ActivityManager: …") that the LEVEL/TAG threadtime format packed into one token
* Logcat clear destroys the running process so its buffered output does not refill the local queue with entries the system buffer was just asked to drop

#### 3.0.8

* The status badge's exit-country flag is now a vector (SVG) flag from the country_flags package instead of a regional-indicator emoji, rendering identically across platforms; it is still clipped to the clover badge and swaps to the country code on tap, with a long press to re-check the IP

#### 3.0.7

* The network-speed card formats the session total ("12.3 MB") instead of printing the raw byte count
* The status badge draws the exit's flag by default and swaps it for the country's abbreviation on tap; a long press still re-checks the IP
* The core page follows Throne's settings_core categories and gains the Xray section's VLESS preference, which picks the core per protocol transport at import time
* The app is Flrone wherever it names itself, and the Testing setting reads "测速" instead of "测速中"

#### 3.0.6

* The Tools page carries the settings entries themselves: General, Appearance, Inbound, TUN, Routing, DNS, Node presets, Testing, Subscriptions, Core, Access control and Backup are one tap away, with no Settings page in between
* A node's menu gains a Speed test submenu (download and upload, download, upload): it tests that node and opens the test panel, whose new Speed test mode row picks the direction for batch runs too
* The node's Edit opens the typed protocol editor, as Throne's does; the JSON document stays reachable as Edit as JSON
* A setting row shows the configured value instead of the example; the example is the dialog's hint and only stands in while nothing is configured
* The proxies page lands on the group that has nodes, and the test panel falls back to the first configuration for its scope

#### 3.0.5

* Settings follow Throne's own list: one Settings entry opens General, Appearance, Inbound, TUN, Routing, DNS, Node presets, Testing, Subscriptions, Core, Diagnostics and Backup directly, and WARP moves inside Routing

#### 3.0.4

* Finish the rename: the first-start prompts, the notification, battery, Wi-Fi and VPN explanations, the update dialogs and the import warnings now call the app flrone, and the suggested backup file name is `flrone-backup.json`

#### 3.0.3

* Rename the app to flrone and move the application id to `com.throneflclash`
* Fix the proxies screen: a latency test now reaches its card while the service is running, instead of only after a restart
* Fix the entry points the walk-through found: saving a group's settings failed silently, a new auto selector had no group and no name, the node JSON editor opened blank, the log page sat under the status bar, the About source link pointed at the upstream repository, and the stopped dashboard probed the mixed inbound every 30 seconds
* An empty backup now says "No backup to restore" instead of asking to restore zero profiles; a backup with no profiles says so too
* The access-control row toggles the app wherever it is tapped, and says why when the selection cannot be edited

#### 3.0.2

* Fix the proxies screen: a server can be picked and its latency measured before the service is started, instead of the two actions waiting for the VPN to be up

#### 3.0.1

* Fix group settings: saving a subscription group failed every time, opening the group could crash on the front/landing candidate list, the routing profile picker showed raw ids, and the update interval reset itself to 0
* Fix the entry points the retired interface left behind: notification actions, the VPN permission prompt, the quick enable/disable shortcuts and the update notification all open their screen again
* Restore `.thrbackup` files opened from a file manager or the share sheet, with the same scope and confirmation as a backup taken in the app
* Start the Wi-Fi permission walk-through when the warning notification is tapped while the app is already open
* Open files shared from other apps: the share stream is delivered as well as the open-with link, and a shared link, subscription or document lands in the importer

#### 3.0.0

* The ported Flutter interface completes the full-parity plan and the old Fragment UI retires: the VPN notification, app restarts and the always-on prompts land in the Flutter host, and the settings screens, protocol editors, JSON editor and their activities are gone
* Settings: the three-column diff closed — every registry key has a form control, grouped like the native screens
* Profiles: typed settings forms for 21 protocol types (Shadowsocks through WireGuard and the long tail), a raw JSON editor with schema validation, completion and formatting, and group settings covering every ProxyGroup field
* Connectivity: a batch test panel (progress, latency histogram, ranked results, speed-test live curve, sort/remove/connect), TV previous/next server switching
* Subscription: change reports surface as dialogs and snackbars; updates walk the Wi-Fi permission flow when a rule needs it
* Diagnostics: a logcat tab beside the core log, first-start prompts in the Flutter host
* Engine: the JSON schema engine (parse, validate, complete, format) ported to Dart with the generated sing-box schema bundled, covered by tests on every push

#### 2.1.0

* Add the B-box Flutter interface as the primary UI (FlClash 0.9.2 presentation over Throne's core); the old Fragment UI stays for one more series
* Route profiles: a rules editor (custom and simple address rules, endpoint preferred-by), the routeprofiles rule-set picker, official preset profiles by country, restore-default rules, and read-only built-in profiles
* Settings: the full Throne surface (inbound, TUN, DNS, routing, WARP, core, testing, presets, subscriptions, updates) with restore-defaults on every page and a restart only when a change needs one
* DNS fields offer the preset servers and the typed history; selecting a configuration now drives the proxies screen and hot-switches the running service
* The configuration document is the group's node list; DNS, routing rules and log settings are app settings, as in Throne
* Close the audited review leftovers: package-name validation on clipboard imports, redacted log exports, off-main-thread app scans and connection closing, safe file pickers, single-delivery intents, and repository-wide LF line endings
* Establish the parity gap audit (openspec/changes/bbox-full-parity) with two diagnostics: the settings three-column diff and the AAR API reference scanner

#### 2.0.4

* Add DNS settings to routing profiles **1**
* Add enable/disable toggle for route rules
* Extend the Multiplex preset and allow custom per-profile Multiplex settings **2**
* Update Xray and add XDRIVE transport **3**
* Share WebDAV backups with Throne desktop **4**
* Add Resolve domain to the profile menu and resolve through the core
* Improve performance with large profile lists, search, subscriptions and logs
* Make cloning a remote routing profile create a local copy **5**
* Move Speed test current connection to the stats bar's long-press menu
* Update sing-box
* Fix rule-set list crash on older devices
* Fix subscription updates failing while disconnected in Proxy mode
* Fix AmneziaWG on devices with UDP GSO
* Fix status bar exit country differing from the IP & country test
* Fixes and Improvements

**1**:
A routing profile can use its own remote and direct DNS servers instead of the ones in Settings › DNS.

**2**:
Multiplex in a profile is now Keep default, On, Off or Custom. Custom gives the profile its own mode (max streams or max connections), padding and TCP Brutal speeds. Xray Multiplex adds max connections, XUDP concurrency and UDP/443 handling.

**3**:
For security reasons, XDRIVE profiles have no share link; import the server's JSON configuration instead.

**4**:
WebDAV backups now use the same backup list as Throne desktop, so backups from all your devices show up together with their device, platform, app version and contents. Backups can be deleted from the list, downloads are checked against it, and each device can be given a name in WebDAV settings.

**5**:
Every update of a remote routing profile replaces its rules, so edits made to it are lost. Its clone is a local copy that is never updated and keeps your edits.

#### 2.0.3

* Add multi-group Auto Selector **1**
* Add input validation to editors and imports **2**
* Add live graphs
* Add core performance profiling in Settings › Diagnostics
* Add log filter
* Add TLS and HTTP version settings for subscriptions
* Add per-subscription update interval
* Add persistent group sorting
* Add TLS fragment options to route rules
* Add cipher suites and the unsafe fingerprint
* Add AmneziaWG QUIC signature generator
* Allow customizing the exit country lookup **3**
* Keep route rules attached to subscription profiles after updates
* Remove Xray forced deprecations
* Fix Auto Selector with Xray profiles
* Fix subscription auto-update after reboot
* Fix subscription URLs with credentials
* Fix TUIC and Hysteria2 link import
* Fix dashboard on older WebView versions
* Fix WireGuard startup memory usage
* Fixes and Improvements

**1**:
An Auto Selector can now track several groups at once.

**2**:
Editors now point out invalid fields, and imports report what was skipped. Extra Core, Chain and Auto Selector profiles are no longer imported.

**3**:
The exit country lookup can be turned off or switched to another service in Settings › Testing.

#### 2.0.2

* Add sing-box dashboard, bundled and enabled by default **1**
* Add automatic Xray geo asset download (geoip.dat / geosite.dat)
* Add subscription info card to subscription groups
* Add include/exclude name filters to subscriptions
* Add network type (Wi-Fi / mobile data) and metered network conditions to route rules
* Add package name regex and "Unknown apps" to route rules
* Add exit IP and country to the status bar
* Add ECH support for Xray and `ech=` share links
* Add certificate SHA-256 pinning
* Allow connecting without rule-sets that could not be downloaded **2**
* Allow editing the running profile
* Allow changing the DNS inbound port
* Make the system HTTP proxy optional and off by default **3**
* Enforce go Tun stack **4**
* Skip unsupported nodes on import
* Fix URL test with Xray balancer configs
* Fix log level setting being ignored
* Fix ECH DNS loop
* Fix XHTTP/TLS share link import
* Fix IPv6 FakeIP range
* Log URL test errors
* Use a monochrome notification icon
* Fixes and Improvements

**1**:
The in-app Clash panel is replaced by the official sing-box dashboard, served by the core's sing-box API (Settings › Core). It ships with the app and opens from the side menu while connected.

**2**:
When a connection fails because remote rule-sets cannot be downloaded, Throne offers to connect without them. They are then downloaded through the proxy and kept for later connections.

**3**:
The local mixed inbound used to be set as the VPN's system HTTP proxy automatically. It is now a separate switch in Inbound settings, off by default, and unavailable while inbound authorization is on.

**4**:
As on desktop, the go Tun stack of sing-box replaces the system/gVisor stacks, giving better performance and fewer compatibility issues.

#### 2.0.1

* Fixed DNS issues and updated the Throne kernel. (Thanks @Mahdi-zarei)
* Completed i18n.
* Fixed some UI issues.

#### 2.0.0

**ThroneForAndroid v2.0.0 — A New Chapter 🚀**

We are thrilled to announce **v2.0.0**, a milestone release that brings a fundamental architectural shift and deep convergence with the **Throne Desktop** ecosystem.

By transitioning to the unified `throneproj/sing-box` core, this version addresses long-standing legacy limitations, resolves numerous open feature requests, and paves the way for seamless cross-platform feature parity.

**🌟 What's New & Major Highlights**

**1. Architectural Evolution: Core Convergence**
* **Unified Core Logic:** Ported core features directly from Throne Desktop, including embedded Xray support, native speed testing (`urlTest`), and advanced protocol routing.
* **Streamlined Migration:** Re-implemented data nodes and parsing logic to align with Throne Desktop, paving the way for smooth profile import/export between devices.

**2. Cleaner Architecture & Feature Deprecations**
* **Plugin System Removal:** Legacy NekoBox plugins have been officially deprecated and removed. With our comprehensive built-in core capabilities, external plugins are no longer necessary, drastically reducing maintenance overhead and improving security.

**3. Android-Native Enhancements**
* Maintained Android-exclusive workflow essentials such as **Per-App Proxy / Bypass Rules**.
* Preserved the intuitive mobile UI while running a desktop-grade networking engine under the hood.

**⚠️ Important Breaking Changes & Migration Notes**

* **New Signing Key & Package Conflict:** Starting with v2.0.0, release APKs are signed with a new signing key to mark a clean separation from pre-v2 builds. Since the package name remains `com.nb4a.throne`, installing v2.0.0 directly over a pre-v2 release will trigger a signature conflict error. **You must uninstall the older release before installing v2.0.0.**
* **Dual Installation & Migration Tip:** If you need to keep your old configuration accessible side-by-side during the migration, the legacy preview debug builds do **not** conflict with the new release key. You can download the last legacy debug APK from [GitHub Actions Run #34730820603](https://github.com/throneproj/ThroneForAndroid/actions/runs/34730820603) to run both versions simultaneously and export your profile details.
* **Config Reset:** Due to sweeping changes in config parsing and node structures, legacy local configurations will not auto-migrate. Please re-import your subscription/profiles upon upgrading.
* **Network Stack Recommendation:** System stack (LWIP/System) is currently undergoing refinement. We strongly recommend using **`gvisor`** as your primary TUN network stack in this release for optimal stability.

**Acknowledgments**

A massive thank you to all contributors and community members for testing, reporting issues, and helping us shape the future of **ThroneForAndroid**!

#### 1.6.4

* 手动颜色主题加入了纯白/暗夜模式，并兼容OLED开关开启纯黑版本
* 主题修改即时生效
* 支持订阅并发更新
* 合并了Own v2.6.0中IPv6等多项修复性改进

#### 1.6.3

* 增加了`OLED暗色模式`
* **尝试**吸纳了[OwnBox v2.5.0](https://github.com/Own716/OwnBoxForAndroid)中对Snell、TLS分片、Hysteria等多项修复性改进

T4A更新至此，已经积累了大量改动。为了确保不因为配置残留导致的异常，本次更新上移了软件版本号。
这意味着：
* 更新后你的订阅和规则会丢失，请**提前导出备份文件**！
* 退回老版本必须卸载重装。

#### 1.6.2

* 修复了关于页URL问题

#### 1.6.1

* **加入了`XHTTP`支持**
* 加入了`自定义图标`功能 **1**
* 修复了切换UI有概率闪退的bug
* 调整了UI细节
* 调整了副版本命名格式：`pc[当前对齐的Throne版本号]-[基于此第几次修改]`

**1**:
受限于Android应用规范，图标替换以创建快捷方式的方式实现。

#### 1.5.11

* 改进了`授权协议`的UI
* 此release标志着新Action工作流运行成功

#### 1.5.10

* 修复了`链式代理`相关的节点切换导致的闪退问题
* 修复了关于页的UI逻辑问题
* 规范LICENSE为`GPL v3.0`正文本身
* 完善了日志记录

🎉ThroneForAndroid（T4A）已正式转移至 `throneproj` 组织名下！ 🚀

即日起，T4A 将作为 Throne 生态的官方 Android 客户端 开展后续迭代。我们将与桌面端进一步紧密协同，持续推进跨平台功能对齐与优化，为大家带来更加统一、丝滑的使用体验。特别感谢 Throne 开发组与社区每一位小伙伴的支持！

#### 1.5.9

* 同步了Throne v1.2.4的`URL 测速`解决方案
* 移除了TCPing和ICMPing代码残留

#### 1.5.8

* 修复了路由资源更新toast不显示的问题
* 改进了OpenSpec执行效率

#### 1.5.7

* 新增了WireGuard协议支持

#### 1.5.6

* 优化了 `扫描二维码` 页面布局，加入了从相册导入的功能。

#### 1.5.2

* **尝试**修复了数据/WiFi切换导致的界面卡顿问题

#### 1.5.1

* 增强了日志记录，方便后继debug
* 完善了singbox内核CI/CD构建

#### 1.5.0

* 备份工具加入了**从Throne电脑版导入**选项，初步兼容Throne v1.2.3的`.thrbackup`格式
* 优化了默认的`屏蔽 QUIC`规则，使其更精确
* 修复了备份页的文字UI细节

#### 1.4.12

* 更新内核到singbox v1.13.16，对齐Throne v1.2.3

#### 1.4.11

* 优化了代码，缓解了订阅自动更新失败的问题
* 进一步清理了移植官核的残留冲突代码
* **尝试**增强了长时间使用的稳定性

#### 1.4.9

* 重构了`URL Test`相关代码，改善了部分订阅中的异常问题。

#### 1.4.8

* 改进了关于`URL Test`的日志保留
* 进一步优化了`URL Test`实现
* **尝试**修复有些订阅会更新失败问题

#### 1.4.7

优化了HTTP代理逻辑，向Throne对齐：
* `禁用混合入栈`就是纯TUN
* 关闭`禁用混合入栈`时就是`127.0.0.1`可连接的
* 允许用户自行设置账密

#### 1.4.6

* 修复了`日志级别`失控的问题

#### 1.4.5

* 解决了`URL Test`闪退的问题

#### 1.4.3

Throne for Android（T4A）从今日起使用sing-box官方内核！

* **大量重构**了内核接驳代码，切换到了Throne同款的sing-box v1.13.15
* 解决了原neko魔改内核导致的dns路由泄露问题
* **暂时**移除了官核没有的并发拨号功能
* **疑似**加入了双网络加速功能
* sniff方式同步sing-box最新版：`探测结果用于目标地址`已废弃
* 路由规则兼容Throne系命名（如`geosite-cn`）
* 简化版本号命名方式

#### 1.4.2-m20-16

* 为预览版提示加入`不再显示`功能

#### 1.4.2-m20-15

* 重构了订阅解析，支持sing-box系订阅加载 **1**
* 调整了默认UA，默认请求Singbox系订阅

**1**:
由于个人订阅节点种类有限，此次改动在一大半的节点种类上尚未经过测试，有bug请及时反馈！

#### 1.4.2-m20-14

* **加入了`禁用混合入站`功能**，Throne同款
* 修复了版本更新检查异常
* 疑似修复了订阅自动更新失效 **1**
* 修复了按键导航栏在某些取色下会不恰当变黑的问题

**1**:
长期稳定性需要大家众测一下，如果稳定没问题请在下方点点赞，谢谢！

#### 1.4.2-m20-10

* 重构HTTP后端，兼容HTTP/2节点

#### 1.4.2-mod-20

本分支正式以Throne for Android命名！

* 同步了Throne的名字和logo
* 合入上游1.4.2-mod-20的UI改进
* 移除了关于页非必要的内容

#### 1.4.2-m20-9

* 调整版本号格式，方便独立feat迭代
* 修复了“路由”和“规则”页在启用SagerNet底栏时挡住最下方内容的问题

#### 1.4.2-mod-19

* 加入了Android 12+的系统主题色同步功能
* 合并上游rules解决方案（2026.07.26）
