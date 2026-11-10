# Kernel speed test, and rules on their own screen (4.1.0)

## Why

Two gaps against the reference apps this fork follows:

- The speed test lived in Dart, built on the batch test session. It could not
  measure one named outbound, had no protocol or provider choice, and reported
  the Android runner's coarse stages rather than a live curve.
- Route rules were a fold inside the profile's settings form: no search, no
  dedicated empty state, and the JSON fragment import an earlier simplification
  dropped was unreachable.

## Changes

- `buildScript/core-patch/core/mobile/speedtest.go` ports Bettbox's tester onto
  sing-box's outbound dialers: Apple mensura, Cloudflare and speedtest.net, h1 /
  h2 / h3 transports, N parallel streams for a fixed duration, 20 latency
  samples with jitter, download/upload loaded latency, RPM, the exit IP, and the
  per-sample curves. It dials through the running instance's own outbound, so a
  measurement uses the hop the user selected; a tag that no longer exists is an
  error rather than a silent direct connection.
- Five gobind calls (`startBettboxSpeedTest`, `queryBettboxSpeedTest`,
  `cancelBettboxSpeedTest`, `bettboxSpeedTestServers`,
  `bettboxSpeedTestOutbounds`) sit behind five new channel methods
  (`speedTest.*`), recorded in `docs/bbox-bridge.md`. `groups.nodes` now carries
  `type` and `isSelector` so the proxy-chain picker can skip rows a hop may not
  be.
- The speed screen is rebuilt on the kernel's snapshot with shared gauge, phase
  and curve widgets (`flutter/lib/components/speed_gauge.dart`), which the batch
  test panel now also draws.
- Rules move to their own page (`flutter/lib/pages/additional_rules.dart`):
  search, drag order, import, add, empty state, per-row edit/delete, and
  read-only handling for built-in profiles.

## Spec deltas

- `connectivity-testing`: the speed test MUST measure through a named outbound
  of the running instance, and MUST honour the configured per-node timeout for
  delay runs.
- `routing-rules`: rules MUST be editable on a screen of their own, reordering
  MUST persist the user-visible order within a profile, and built-in profiles
  MUST stay read-only.
- `repository-governance`: `docs/bbox-bridge.md` MUST list every channel method
  and every payload shape the bridge emits.
