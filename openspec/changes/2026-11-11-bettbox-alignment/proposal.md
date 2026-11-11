# Full Bettbox alignment (ADR 0002)

## Why

`docs/adr/0001-ffi-boundary.md` settled the FFI boundary conservatively: Kotlin
owns the data plane, the 423 typed `throne_*` exports stay, and a Bettbox-style
JSON action bus is explicitly out of scope. The user asked for the whole project,
kernel architecture included, to be aligned with Bettbox; ADR 0001 is superseded
by `docs/adr/0002-bettbox-alignment.md`.

The transport layer was never the gap. `dartbridge.go` already posts
`Dart_PostCObject_DL`, `throne_kernel.dart` already wires
`NativeApi.initializeApiDLData` and the message port, `kernel_worker.dart` already
runs one long-lived isolate that owns the Instance handle, and Go already pushes
`{"method","data"}` JSON events. What is missing is Bettbox's protocol layer: one
`invokeAction` C entry point, `Action{id,method,data}` / `ActionResult{id,data,code}`,
`id -> Completer` correlation, and a generic `invoke<T>`.

The data plane cannot move without also changing storage: roughly 120
`ThroneBoxBridge.kt` handlers read Room v20 (seven `@Entity` classes) and
`DataStore`, neither of which is reachable from the Go process. Bettbox stores
profiles as JSON files under an app-private path, which is why its data plane can
live in Go/Dart.

## Changes (phased; each phase is its own PR and preview release)

- **Phase 0 (this change)**: ADR 0002, the superseded marker on ADR 0001, a
  note in `docs/bbox-bridge.md`, and `tools/diagnostics/action_contract.py`
  wired into `ci.yml`. The audit is a no-op until the protocol files exist, then
  enforces that Go `Method` constants, the dispatcher registry and the Dart
  `ActionMethod` enum agree by wire string. Bettbox itself has a measured drift
  here (`resetConnectionsMethod` vs `resetConnections`), which this gate exists
  to prevent.
- **Phase 1**: `action.go` / `action_bridge.go` in the core patch, a single
  `//export throne_invoke_action`, the declaration in both copies of
  `bridge_symbols.h`, one `_lookup` in `throne_ffi.dart`, and `action.dart` +
  `invoke<T>`/`Completer` correlation in `throne_kernel.dart`. The 424 typed
  exports remain as the handlers' implementation; `symbol_audit.py` stays green.
- **Phase 2**: `flutter/lib/data/document_store.dart` (atomic JSON writes, version
  field) and `RoomToJsonMigration.kt` (one-time Room v20 -> JSON export with an
  explicit id map, Room kept read-only as a fallback). `schema_audit.py` gains a
  JSON-snapshot check. Migration tests use a real v20 sample before the read
  source switches.
- **Phase 3**: `routes.*` -> `profiles.*` -> `settings.*` -> `config.build` ->
  `speedTest.*` move to action handlers, with the matching `when(call.method)`
  arms deleted from `ThroneBoxBridge.kt` in the same commit so
  `channel_audit.py` stays bidirectional. Speed-test progress becomes a Go push
  instead of a 250 ms poll. Kotlin keeps VpnService/TUN fd, notifications,
  `state.stats`, `wifi.watch`, `apps.*`, SAF backup, `data.path`, and the
  `ffi.mode` / `ffi.handle` handover.
- **Phase 4 (later plan)**: Riverpod and the dual Flutter engine. Phase 0-3 keep
  `BoxController extends ChangeNotifier` and the single engine; they are
  functionally equivalent to Bettbox's two-engine setup.

## Verification

Every phase runs the full local rebuild (`buildScript/local-env.sh` then
`build-core.sh`, `gen-local-schema.sh`, `flutter build aar`, and
`./gradlew app:testOssDebugUnitTest app:assembleOssDebug`), all diagnostics
(including `symbol_audit.py`, `channel_audit.py`, `action_contract.py`),
`flutter analyze --fatal-infos`, `flutter test`, the Kotlin unit tests, and a
device regression covering the Room -> JSON upgrade path.
