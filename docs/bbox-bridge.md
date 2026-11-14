# The Core host

> Status 2026-11-14: rewritten after the migration to upstream FlClash v0.9.3's own interface. The
> page-level bridge (`ThroneBoxBridge.kt`, `Capabilities.kt`, `BboxBridge.kt`, `BboxCatalog.kt`,
> `BboxCommands.kt`, `BboxTrafficMeter.kt`, `BboxEgress.kt`) is **deleted**. There is no
> `io.flrone/box` / `io.flrone/events` contract and no `channel_audit.py` gate any more.

The app runs FlClash's own Flutter interface on Throne's runtime. FlClash's screens do not speak a
page-level channel: they speak the **Core wire protocol** — a JSON `{id, method, arguments}` in, a
JSON `{id, result}` or `{id, error:{code, message}}` out, plus a `message` event carrying batches —
exactly as upstream's Go core implements it (`core/protocol.go`). Throne answers that protocol
natively, so the whole interface works with no bridge layer of its own.

## Shape

```
   FlClash UI (flutter/lib, package fl_clash)
        │  MethodChannel com.follow.clash/core   ("invokeMethod" + "event")
        ▼
   ServicePlugin  ─────────────► ThroneCore.invokeMethod(data, callback)
   (app/src/main/java/com/follow/clash/plugins)          │
                                                         ▼
                                        ThroneCore.kt (object, io.throne.bbox.corehost)
                                                         │
                    GroupRepo · ProfileManager · ProfileImport · SubscriptionQueue
                    SettingsMapper · DataStore · CoreConfigs · SagerNet · CoreLog
```

`ThroneCore` is the single Kotlin implementation of the protocol. It is **not** a second state
store: a FlClash profile id *is* the matching Throne group id, `proxy.list` reads `GroupRepo`, and
the running box is whichever `ProxyInstance` `SagerNet` owns. Nothing is mirrored, so nothing can
drift.

## What ThroneCore answers

| Area | Wire methods | Backed by |
| --- | --- | --- |
| Lifecycle | `core.init`, `core.initialized`, `core.gc`, `core.memory` | `initialize()`/`close()` register the `GroupRepo.Listener` and the log pump; memory reads this process's heap and `Debug.MemoryInfo.totalPss`, because the Go runtime shares the app process — there is no separate core process to measure |
| Profile documents | `config.setup`, `config.update`, `config.validate`, `config.read`, `profile.base`, `profile.outbounds`, `profile.build`, `profile.clearEffect` | `ProfileImport.parse` validates and imports; `GroupRepo` + `ProfileManager.members` produce the Clash-shaped document; `buildProfile` calls `GroupRepo.setCurrent` |
| Throne profiles | `throne.profile.list`, `throne.profile.save`, `throne.profile.update`, `throne.profile.delete` | `GroupRepo` + `SubscriptionQueue`; a group's subscription metadata becomes the card's quota and expiry. These four are the only methods Throne *added* to the protocol, for FlClash's profile cards |
| Proxies | `proxy.list`, `proxy.select`, `proxy.definition`, `proxy.testDelay`, `proxy.convert`, `proxy.validate`, `shareLink.encode`, `shareLink.decode`, `filter.validate` | Every Throne group becomes a `Selector` group; the `type` is the Dart enum *name* (`Selector`) because `buildGroups` filters on `GroupTypeExtension.valueList`. Member names are made globally unique. `proxy.select` writes `DataStore.selectedProxy` and `GroupRepo.setCurrent` |
| Traffic | `traffic.current`, `traffic.total`, `traffic.reset`, `network.changed` | `StatusMessage` cumulative counters, differenced over elapsed wall time. `traffic.current` answers a per-sample rate: the UI appends it to a speed series. It is deliberately not `queryOutboundStats`, which hands out and zeroes a delta and would steal the bytes `TrafficLooper` counts into the profile totals |
| Egress | `probe.outboundIp` | The selected node's stored `ipOut`, `testCountry` and `latency` |
| Logs | `log.start`, `log.stop`, plus the `log` event | A 250 ms tail of `CoreLog.file`, batched at most 200 events per `message`, so a startup flush is one Flutter-thread post instead of thousands |
| Service | `listener.start`, `listener.stop` | `ThroneServiceController` → `SagerNet.startService()` / `stopService()` |

Clash-only features answer an explicit `unsupported_capability` error rather than fabricated empty
data, so the UI can never mistake "not supported" for "supported and empty": `connection.*`,
`provider.*`, `ruleSet.*`, `geo.update`, `route.*`, `probe.services`, `mitm.*` and `config.decrypt`
have no Throne counterpart. `proxy.validate` and `filter.validate` answer an empty array — Throne's
own importer is the validator, and its filters live on the group row.

Request ids are keys: a reused id answers the displaced request with `core_error` instead of leaving
it to time out, and a late result is delivered only if its callback is still the pending one.
`close()` drains every pending callback with `transport_disconnected`.

## The Dart side of the protocol

`flutter/lib/core/` is upstream's own Core client apart from the profile methods:

* `lib.dart` (`CoreLib`) owns the lifecycle and mints request ids; `service.dart` (the `Service`
  transport) talks to `com.follow.clash/service` and `com.follow.clash/core`.
* `method.dart` is the `CoreMethod` enum of wire names; Throne's four `throneProfile*` entries are
  added there.
* `event.dart` decodes the `message` batches into `CoreEvent`s (`log`, `delay`, `loaded`, …).
* `throne_profiles.dart` (a new file) is the typed client for `throne.profile.*`, used by bootstrap
  and by the profile actions.

## The six surviving runtime helpers

Everything else under `app/src/main/java/io/throne/bbox/bridge/` was presentation state and is gone.
What is left are pieces the *runtime* needs; none of them participates in the UI.

| File | Role |
| --- | --- |
| `BboxMode.kt` | The outbound-mode switch (Rule / Global / Direct). Throne has no `route.final`, so the mode rewrites the route profile handed to the config generator: Global drops the rules and sends everything to `proxy`, Direct to `direct`, Rule returns the profile untouched. The `hijack-dns` rule survives every mode, or the core's own DNS requests would leave unhandled. Stored in `DataStore.configurationStore` as `bbox_outbound_mode`. |
| `BboxRuntime.kt` | The process-wide entry point for that rewrite. `routingInput(base)` is called by `CoreConfigs.buildMain`, so a reload from a tile, widget or shortcut honours the mode too. |
| `BboxKernel.kt` | The FFI driver's Kotlin half. `ffiMode` tells the service to stand aside; `buildStartOptions()` builds the start payload from the selected profile without creating a gobind `Instance`; `markRunning()` / `clearRunning()` keep `runningProfiles` and `runningRouteId` truthful, which two deletion guards read; `handOver()` stops a service-owned box so two boxes never fight over one tun; `onReloadWanted` and `onWifiChanged` are how a non-Dart reload and an SSID change reach Dart. |
| `BboxCorePlatform.kt` | The `CorePlatform` implementation for the FFI path: tun and `VpnService`, `protect()`, DNS, network and Wi-Fi state, notifications — the Android duties behind the C callback table, mirroring what the gobind `NativeInterface` does for the service-owned path. `SagerNet` installs it into `io.throne.bbox.core.Core.setPlatform`. |
| `BboxMemory.kt` | System memory trimming: the `onTrimMemory` policy (tell the UI first, then `gc()` and `dalvik.system.VMRuntime.trimHeap` above API 28). The Go runtime is in this process, so there is no core-side GC call to make. |
| `BboxWarp.kt` | WARP identity registration behind the settings row: `WarpClient.register(tunnelType)` plus the amnezia I1–I5 packet generation, saved through `DataStore`'s warp fields. |

`BboxFlutterActivity` holds no backend state. It registers the four FlClash platform plugins —
`AppPlugin`, `BatteryPlugin`, `ServicePlugin`, `TilePlugin`, the same set upstream's `MainActivity`
adds — and nothing else. `ThroneServiceController` (in `corehost/`) supplies the service lifecycle
contract those plugins expect on top of Throne's own `VpnService`: it resolves the group and member
to start, forwards `syncState` into `DataStore.serviceMode`, and answers `getRunTime`.

## Channels the host serves

Channel names are upstream's, unchanged (`Components.PACKAGE_NAME` is `com.follow.clash`):

| Channel | Kind | Served by |
| --- | --- | --- |
| `com.follow.clash/app` | MethodChannel | `AppPlugin` — package list and icons, VPN permission, notifications, shortcuts, exit |
| `com.follow.clash/battery` | MethodChannel | `BatteryPlugin` — battery-optimisation exemption request |
| `com.follow.clash/battery/optimization` | EventChannel | `BatteryPlugin` — the exemption state |
| `com.follow.clash/service` | MethodChannel | `ServicePlugin` — `init`, `shutdown`, `start`, `stop`, `getRunTime`, `syncState`, plus the `event` push |
| `com.follow.clash/core` | MethodChannel | `ServicePlugin` → `ThroneCore` — `invokeMethod` carrying the JSON request |
| `com.follow.clash/tile` | MethodChannel | `TilePlugin` — the quick-settings tile's `start` signal |

Both ends derive these names from the same `com.follow.clash` literal, so a rename has to move
`flutter/lib/common/constant.dart` and `Components.kt` together.
