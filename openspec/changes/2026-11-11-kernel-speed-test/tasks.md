# Tasks — kernel speed test and separate rules screen

- [x] Port Bettbox's tester into `buildScript/core-patch/core/mobile/speedtest.go`
      (three providers, h1/h2/h3, parallel streams, jitter, loaded latency, RPM,
      exit IP, per-sample curves).
- [x] Expose it through gobind and five `speedTest.*` channel methods; record
      them in `docs/bbox-bridge.md`.
- [x] Reach the Dart-owned FFI instance: three handle-based C ABI exports
      (`speedtest_bridge.go`, declared for the shim in
      `android/core/src/main/cpp/speedtest_symbols.h`), JNI wrappers on
      `io.flrone.core.Core`, and a two-level instance resolution in
      `BboxSpeedTest` — service instance first, the handle Dart registered over
      `ffi.handle` second. `speedTestStart` now rethrows every failure except a
      genuine "already running", and a panicked test releases the kernel's
      single slot instead of wedging it. Verified on the emulator in FFI mode:
      the test starts through the handle, the outbound picker loads, the real
      failure reason shows, and "Test again" restarts cleanly.
- [x] Widen `groups.nodes` with `type` and `isSelector` for the chain picker, and
      keep its wire test in step.
- [x] Rebuild the speed screen on the kernel snapshot; share the gauge, phase row
      and curve with the batch panel.
- [x] Narrow a node's speed entry to one direction (`testDownload` / `testUpload`).
- [x] Move rules to `additional_rules.dart`; restore the JSON fragment import and
      make built-in profiles read-only there.
- [x] Fix the proxy-chain picker's crash (Material checkbox row in a dialog frame
      without a Material ancestor) and skip rows a hop may not be.
- [x] Cross-compile the core for android/arm64 with the Android build tags.
- [x] `flutter analyze` clean; 437 Flutter tests pass; `channel_audit.py` clean.
- [ ] Device check on arm64 once the preview lands (Issue #17 tracks the matrix).
