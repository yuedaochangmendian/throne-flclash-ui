# Tasks — kernel speed test and separate rules screen

- [x] Port Bettbox's tester into `buildScript/core-patch/core/mobile/speedtest.go`
      (three providers, h1/h2/h3, parallel streams, jitter, loaded latency, RPM,
      exit IP, per-sample curves).
- [x] Expose it through gobind and five `speedTest.*` channel methods; record
      them in `docs/bbox-bridge.md`.
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
