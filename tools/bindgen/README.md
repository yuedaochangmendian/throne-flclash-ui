# bindgen — the self-owned kernel surface (Dart FFI direct)

Replaces both the gobind Java binding layer and the kernel method channel with a
three-way generated surface the repository owns. Architecture:

    Dart ──dart:ffi──▶ throne_* C ABI ──▶ Go package mobile ──▶ sing-box core
      ▲                                     │
      └── ReceivePort ◀── Dart_PostCObject ─┘   (events: logs, test results)
    Kotlin ──JNI──▶ libcore.so ──▶ same C ABI      (Android duties: startTun(fd,
                                                     TunInterface), platform calls)

No method channel is involved in kernel control; the channel remains for Android
duties only (VpnService, notifications, platform databases).

## What it emits

    python3 tools/bindgen/bindgen.py --emit all --out build/bindgen \
        --go-src ../throne-go/core_mobile

| File | What |
|---|---|
| `surface.json` | Every crossing, classified `java_to_go` / `constructors` / `go_impl_calls` / `jni_callbacks` / `port_events` |
| `bridge_symbols.h` | The C ABI contract: per-crossing prototypes + `throne_callbacks_t` + the runtime (`throne_start_tun`, `throne_free`, ports) |
| `bridge_calls.go` | Go `//export` bodies (package `mobile`, patched in via `buildScript/core-patch`) |
| `bridge_runtime.go` | Handle table, error channel, message port, `bridgePlatform` (routes PlatformInterface → `throne_callbacks_t`) |
| `dartbridge.go` | `Dart_PostCObject` glue (bettbox dart-bridge) |
| `throne_ffi.dart` | Dart `dart:ffi` raw lookups + typed handle wrappers |

`android/core/src/main/cpp/bridge_symbols.h` is the same contract consumed by the
JNI shim (regenerated together).

## Marshalling rules

- Everything that is not a primitive or a string crosses as an `int64_t` handle
  (the role `go.Seq`'s refnum played).
- Strings return as `char *` allocated by Go; the caller frees with `throne_free`.
- The 19 `throws` methods report through `throne_last_error()`; the Dart
  wrappers raise on non-empty.
- `byte[]` crosses as `const uint8_t *` + length.

## Who implements each interface (decides the crossing direction)

| Implementer | Interfaces | Mechanism |
|---|---|---|
| Go | 9 iterators, TunOptions, InterfaceUpdateListener | Plain C ABI calls on handles (`throne_<Iface>_<method>`) |
| Platform (Kotlin) | PlatformInterface, LocalDNSTransport, Func | `throne_callbacks_t` filled by `JNI_OnLoad` (bettbox `registerCallbacks`) |
| Platform (Dart) | LogSink, URLTestHandler, IPTestHandler, SpeedTestHandler | Dart ports: the message port for logs, per-call reply ports for tests |

Parameter adaptations where the crossing shape changes: `PlatformInterface` and
`LogSink` parameters drop (global bridge / message port), test-handler
parameters become `int64_t` ports, `StringIterator` parameters become JSON
arrays, `Func` becomes a JNI object pointer.

## Measured surface

| | count |
|---|---|
| Java → Go crossings | 340 |
| Constructors | 25 |
| Go-implemented interface calls | 45 |
| JNI-callback interface methods | 19 (the `open_tun` establish callback + `protect`/`resolverProcess` as TunInterface + the platform duties) |
| Port events | 8 |
| Classes in the bound API | 44 |

The fd path supports both shapes (bridgePlatform.OpenTun): a pre-fed fd from
`throne_start_tun` (VpnService established first) is returned as is; otherwise
the `open_tun` callback establishes the VPN mid-start — Kotlin builds
`VpnService.Builder` from `throne_TunOptions_toJSON`, establishes, and feeds the
fd back with `Core.startTun(fd, TunInterface)`.

## Migration state

Done (kernel operation surface, dual path with channel fallback): service
lifecycle (`service.start/stop/reload` → `Mobile.newInstance` + `Instance.*`),
outbound mode, profile/group selection, WARP registration (`Mobile.warpRegister`
+ `genQuicSignature`), and the status/traffic stream (`Instance.status` polling
→ `rates`/`dashboard` events). The `:bg` process is gone — Flutter engine,
Kotlin and the Go core share one process.

Still on the channel (next batches): the test sessions and auto-selectors
(their orchestration owns DB persistence — they move with the storage
migration's end state), the connections screen (the core's HTTP control API via
OkHttp), and the app-data surface (profiles/routes/settings CRUD).

## What is here today

`bindgen.py` reads the sources jar (the fixed contract) and the core's Go
sources (`--go-src`, for resolving Java `getX` to the real Go field-vs-method
name), and emits the three halves above. Everything it writes is generated;
edit the generator, never the output.
