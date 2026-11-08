# The B-box bridge

> Status 2026-11-03: current. `Capabilities.kt` is the source of truth for what exists; `tools/diagnostics/channel_audit.py` (wired into CI) enforces the Dart/Kotlin contract on every push.

The ported interface (`:bboxui`) renders one immutable snapshot and sends every gesture through one object. Throne's
backend does not work that way: its state lives in four places and the old fragments read each of them directly. This
document describes the layer in `app/src/main/java/io/throne/bbox/bridge` that reconciles the two, replacing the
fragment-owned service connections of the old UI.

## Why a bridge at all

B-box's screens (FlClash's) are written against a controller that exposes

* a snapshot — `dashboard`, `groups`, `profiles`, `preferences`, traffic history, logs, connections;
* an action bus — `box.act('mode.set', {...})`, `box.act('service.start')`, `box.act('proxy.select', {...})`;
* change notifications — one flow per aspect, so a screen rebuilds only what changed.

Throne instead has `ISagerNetService` (a bound AIDL service with speed/state callbacks), `ProfileManager` and
`GroupRepo` (Room repositories with in-process listeners), `DataStore` (a preference store), and `RouteManager`
(the routing profiles). Reproducing B-box's screens faithfully means giving them the first shape; the bridge is that
translation, not a set of adapters bolted onto each screen.

## Shape

```
        ┌──────────────────────────── BboxBridge (singleton) ───────────────────────────┐
        │  state: StateFlow<BboxUiState>        meter: BboxTrafficMeter                  │
        │  one SagerConnection   GroupRepo.Listener   ProfileManager.Listener           │
        └───────▲───────────────────────┬───────────────────────────┬───────────────────┘
                │                       │                           │
     SagerConnection callbacks     BboxCatalog.load()          BboxEgress.probe()
     (state, speed, selector)      (groups, profiles)         (mixed inbound)
                │                       │                           │
        ┌───────┴───────────────────────┴───────────────────────────┴───────────────────┐
        │  BboxCommands : BboxActions — the write half                                  │
        └───────────────────────────────────────────────────────────────────────────────┘
```

| File | Role |
| --- | --- |
| `BboxBridge.kt` | Owns the single service connection and both repository listeners, mirrors everything into `BboxUiState`, debounces bursts of change notifications, ticks the run time and memory once a second. |
| `BboxCatalog.kt` | Maps the catalog: a Throne group is a B-box group, its members are the nodes, the selected profile is the selection; a subscription group is also a B-box profile card with its quota and expiry. |
| `BboxTrafficMeter.kt` | Turns `SpeedDisplayData` into the dashboard's rates, totals and the two 30 point sparklines; the window is one sample per second while the service runs, so it spans half a minute. |
| `BboxMode.kt` | The outbound mode switch, implemented as a routing-profile rewrite (see below). |
| `BboxEgress.kt` | The outbound IP, country and organisation, probed through the running mixed inbound (or over the phone's own connection while stopped). Five sources are raced at once with an 8 s budget, the richest one preferred; the answer names the source that won. |
| `BboxCommands.kt` | Every write: start/stop, mode, selection, tests, subscription refresh, delete, open URL. |
| `BboxRuntime.kt` | Installs the bridge from `SagerNet.onCreate` in the main process and hands `CoreConfigs` the mode-aware routing input. |
| `app/.../flutter/ThroneBoxBridge.kt` | The host of B-box's own channels: turns this state into the `dashboard` / `rates` / `profiles` / `groups` events and the actions into the calls the Flutter screens make. |

## Data mapping

| B-box | Throne | Note |
| --- | --- | --- |
| `dashboard.status` | `DataStore.serviceState` + the service's `profileName` | `startedAt` is stamped when the state first becomes `Connected`, since Throne keeps no start time. |
| `dashboard.modes` / `mode` | `BboxMode` (stored in the configuration store) | Rule / Global / Direct, see below. |
| `dashboard.groups[]` | `GroupRepo.all()` + `ProfileManager.members(gid)` | `selected` is `DataStore.selectedProxy`. |
| node `delay` / `testedAt` | `ProxyEntity.latency` / `latencyAt` | Seconds in the row, milliseconds in the model. |
| `dashboard.profiles[]` | subscription groups (`ProxyGroup.isSubscription`) | `traffic` / `expiry` come from `SubUserInfo` (`groups.sub_metadata_json`). |
| `dashboard.egress` | `BboxEgress` | IP, country, organisation, ASN, address family, the endpoint that answered, and `direct` when no tunnel carried the request. |
| `dashboard.memory` | `Runtime` + core's `/memory` (`BboxApi.memory`) | `core`/`rss` come from the core's `/memory` (`inuse`, falling back to `rss`); `app`/`heapInuse` is the host process's used heap. The roles can swap across sing-box builds, which is why both are on the wire. |
| `dashboard.intranet` | `lanWire` / `lanSet` | The mixed inbound's "Allow LAN" and its port; the panel shows the active bindings. |

## Actions

| Action | Implementation |
| --- | --- |
| `toggleService` | `SagerNet.startService()` / `SagerNet.stopService()`; a start with nothing selected is refused and logged. |
| `setMode` | `BboxMode.set` then `SagerNet.reloadService()` when running. |
| `selectProxy(group, tag)` | Resolve the profile by name, write `selectedProxy` + `currentProfile`, broadcast `Action.SWITCH_PROFILE` so a running core switches instead of restarting, then reload the rows. |
| `testGroup` / `testProxy` | `TestSessionClient.start(TestSpec(KIND_URL, ...))`; the results are persisted by `:bg` and arrive back through `ProfileManager.Listener`. |
| `selectProfile` | `GroupRepo.setCurrent`; when stopped, the group's first member becomes the selection. |
| `updateSubscription` | `SubscriptionQueue.refreshGroup(gid, showDiff = true)`. |
| `deleteProfile` | `GroupRepo.delete` (its profiles go by the foreign key cascade). |
| `openUrl` | `ACTION_VIEW` on the application context. |
| `groups.visible(visible)` | `BboxGroupsWire` through `ThroneBoxBridge.setGroupsVisible` | `ready` and the one-second pump carry group **counts** only (`nodeCount`, `timeouts`). The Proxies screen turns rows on while it is open and off when it closes, so the largest payload the bridge builds only exists while a screen renders it. |
| `groups.nodes` | `BboxGroupsWire.nodes` | The rule editor's outbound picker: every node's id and tag, flat, without the per-node rows of the catalog event. |

## Outbound mode

Throne has no `route.final` switch; a route profile's default outbound and rule list decide where traffic goes. The
switch therefore rewrites the profile it hands to the config generator, in `CoreConfigs.buildMain`:

* **Rule** — the profile exactly as saved (no allocation, the common path).
* **Global** — the profile's rules are dropped and the default outbound becomes `proxy` (the started profile).
* **Direct** — the same, with `direct` as the default outbound.

The `hijack-dns` rule survives every mode: without it the core's own DNS requests would leave unhandled. The rewrite
happens on a copy, so the stored profile and the desktop's `.thrbackup` files are never modified.

## Lifecycle

`SagerNet.onCreate` installs the bridge in the main process only. That is earlier than any activity, so the first
frame already has the service state and the catalog; it also survives rotation, which the old per-fragment connection
did not. `BboxFlutterActivity` therefore holds no backend state of its own — it registers the channel host and lets the
Flutter screens read the flow.

The `:bg` process is untouched: it still builds configs, runs the core and persists test results. `BboxMode` is read
in `:bg` when a config is built, from the same shared preference table, so a start triggered by the tile or a shortcut
honours the mode as well.

### The FFI driver runs the core; the bridge steps aside for the control plane

Since 3.3.0 the Dart driver owns the core again: `KernelService.initialize()` tells the bridge to stand aside
(`ffi.mode`), opens `libthrone.so` in the worker isolate and drives start/stop/reload plus the status snapshot over
the `throne_*` C ABI. The channel keeps the data plane — profile storage, `config.build`, subscriptions, test
sessions — and Android duties (VpnService, notifications, the platform databases), exactly as ADR 0001 splits them.

The driver still yields on its own when the rebuilt core is absent from the build: `ThroneKernel.isAvailable` is
checked before `ffi.mode` is touched, so an AAR without the patch leaves `BaseService` starting `ProxyInstance`
through gomobile and every control call on its channel branch. `kFfiDriverEnabled` in `kernel_service.dart` is the
single switch for the whole path; turning it off restores the pre-3.3.0 operator without deleting the driver.

### What the driver has to report back (FFI driver only)

Four things the service used to do while it owned the core are now the driver's job, because they are answers only
the running box can give:

- **Running-config facts.** `state.markRunning` / `state.clearRunning` keep `DataStore.runningProfiles` and
  `runningRouteId` in step with the box. `ProfileManager.runningUses` refuses to delete a node a running chain still
  uses, and `RouteManager.runningRouteId` decides whether a group's routing change needs a reload; both read the
  store, so a driver that never writes it silently disables two guards. The values come straight from `config.build`,
  and they are written after `worker.start()` held — not when the config was built, which would leave stale facts
  behind whenever the core refuses to come up.
- **Domain resolution.** The diagnostics screen and its `dns.resolve` channel went away, and the AIDL method,
  `DomainResolver` and the Dart driver path went with them. The C ABI's `Mobile.resolveDomains` stays in the core
  patch (it is part of the throne_* surface, not something the UI owns); nothing calls it today. Subscription
  filtering never needed any of this: its request carries a full test config, so the core builds a probe box when
  no instance is passed.
- **Wi-Fi rules.** The monitor has to live on the Android side (it owns the ConnectivityManager callback), but the
  core that re-reads the SSID is Dart's. `wifi.watch` starts the monitor when the box says it needs Wi-Fi state;
  each change comes back as a `wifi.state` event and the driver calls `Instance.updateWIFIState()`.
- **Notification speed.** `TrafficLooper` needs a `ProxyInstance` for its `TrafficUpdater`, so in ffiMode it never
  starts and the notification's speed line stays at zero. The driver pushes its status snapshot through
  `state.stats` instead, which lands in the same `SpeedDisplayData` the looper would have produced.

A service that comes up before Dart (START_STICKY, always-on VPN, a widget) has already built its own box by the time
`ffi.mode` arrives. Two boxes on one tun fight over the same descriptor, so `BboxKernel.handOver()` stops the
service-side one and restarts the service in place; the ffiMode branch keeps the notification and leaves the core to
Dart, which rebuilds it from `KernelService.adoptService()` once the channel can answer `config.build`.

### The heartbeat is a liveness question, not a data question (FFI driver only)

`throne_status_snapshot` is polled once a second from the worker isolate. Reading the traffic counters can race a box
that is closing, so the read is fenced; when it panics it answers `{"alive":1}` rather than an empty string. An empty
answer used to mean "the kernel is gone" to the driver, which closed and reopened a tunnel that was still moving
traffic — the start/restart loop. Before a miss is counted the worker now asks `throne_Instance_alive`, which is
`started && !closed` on the box and cannot race the counters. Only a box that really stopped is recovered.

Every lifecycle step writes a `[lifecycle] …` line into `core.log` (start, stop, reload with its reason and origin,
heartbeat loss, start failure), and the service writes `[service] state -> …` on each transition. The log screen tails
that same file, so a restart loop reads as a sequence instead of a mystery.

### The host owns the core handle when the engine dies (FFI driver only)

The Go handle table is process-wide, so the numeric Instance handle outlives the Dart isolate that created it. `KernelService` registers it with the host over `ffi.handle` after a start holds and clears it on every stop and failed start. A stop from a widget, tile or notification never goes through the UI's own stop action: while the UI is attached the bridge emits `serviceStop` and the driver closes the core itself; once `cleanUpFlutterEngine` has run there is no subscriber, so `BaseService.stopRunner` calls `BboxKernel.closeAdoptedCore()` — a new `Core.closeInstance(handle)` JNI thunk over `throne_Instance_close` — instead of leaving the tunnel up until the process dies. A new engine receives the same handle in `ffi.mode`'s reply and adopts it through `KernelWorker.adoptInstance`, which re-wraps the live handle rather than building a second box on the same tun.

## The data plane moves to Dart

`sager_net.db` is opened by Room, and Room opens it with `WRITE_AHEAD_LOGGING` — `SagerDatabase` says so and names
the reason: a reader in one process runs while the other writes. Nothing stops a third connection in the Dart isolate
from doing the same, so the data plane does not need a protocol between the two sides. It needs a path, which Dart
cannot derive (`/data/data/<pkg>/databases` requires a package name it does not have), so `data.path` answers once —
on the first route-list read, not at startup — with the file and the schema version Room actually opened at, read
from the file, not from the annotation, because a downgrade makes those two disagree.

The library is the platform's own `libsqlite3.so` over `dart:ffi`, not `sqflite`. That is not a preference: this
module's AAR cannot register plugins. `flutter build aar` publishes a `GeneratedPluginRegistrant` the host loads by
reflection and **swallows** on failure, which is why `BboxFlutterActivity.registerScannerPlugin` exists at all. A
`DynamicLibrary` has no registrant. `flutter/lib/data/sqlite.dart` is the whole binding.

What is live today is one table's **read**: `route_profiles`, joined to `route_rules` for the two counts and to
`settings` for `current_route_id`, through `RouteProfilesDao`. `RouteProfilesSource` prefers it on the route list and
the route editor and falls back to `routes.list` over the channel on every failure — no `libsqlite3.so`, no
`data.path` answer, an unexpected schema, a SQL error, or an empty table. The empty case is deliberate: on the host
side `RouteManager.all()` would call `ensureDefault()` and **write** a profile, which a read-only Dart connection
must never do. The SQL reproduces `BboxRoutes.list()`'s wire shape, so the fallback is invisible to the screen.

`groups` (through `GroupsDao`) remains the un-wired vertical slice: it proves that a second connection lives beside
Room's and pins the column names, but no screen calls it and release AOT tree-shakes it. The remaining tables
(`profiles`, `SettingEntry`, `MarkerEntity`) follow the same shape, table by table, with writes only after reads are
trusted on a device.

Two rules keep this from drifting:

- `schema_audit.py` compares `@Database(version = …)` with `roomSchemaVersion` in `db.dart` on every push, and also
  column-checks every SELECT in `flutter/lib/data/*_dao.dart` against Room's exported schema JSON
  (`app/schemas/…/<version>.json`). A version bump on one side alone still compiles and still queries — it just reads
  the wrong column, silently; so does a migration that renames or drops a column the SQL mentions by name (the query
  throws, `RouteProfilesSource` catches, and the channel answers forever with no report). Both now fail the push.
- `DataLayer.attach` answers null for every failure (no library, no path, unexpected schema). A null means "keep using
  the channel", the same contract `ThroneKernel.isAvailable` has on the kernel side.

What stays on the channel is what Dart cannot reach: the platform (`VpnService`, notifications, the widget, SAF,
`PackageManager`, Logcat) and the host's own state machine (`DataStore.serviceState`, `ProfileManager`'s caches).
Neither is a gap in the migration — they are the parts that were never data.

## Not wired yet

These fall through the dispatch to the `unsupported` error. They are the B-box features Throne has
no counterpart for (the manifest in `Capabilities.kt` is the single source of truth): `terminal`,
`capture.*`, `remote.*`, `reports`, the `stun` / `quality` tools, `endpoints` (tailscale / openvpn /
openconnect / usbip), `taildrop`, `perAppManaged` (no Shizuku-managed package list), `rootQuery`
(packages come from PackageManager only), `dnsObject`, and `warp` as a dedicated page (WARP is
configured through the core). `apps.permission` answers with a refusal rather than an absence: the
list needs no Shizuku grant.

Wired since the earlier drafts of this file: the connections and logs screens (`BboxApi.connections`
over the clash API, `BboxLogs` over `CoreLog`), profile import (`addProfile` and the scanner/file
flows) and the per-node probe (`dashboard.probe.*` with `dashboard.qualityCache.*`). The
domain-resolution tool shipped here once and left with the diagnostics screen (see the driver note
above).

File payloads the platform hands the app land here too: `files.open` takes a `content://` or
`file://` Uri and answers either with the `backup` envelope of a `.thrbackup` (the same shape
`backup.create` returns, so the restore confirmation is the one the backup page uses) or with the
editor's seed for a document, decided by the container's "THRN" magic rather than by its name.
