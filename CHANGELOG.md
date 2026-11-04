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
