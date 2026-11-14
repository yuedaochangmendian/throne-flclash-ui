#!/usr/bin/env python3
"""Regression tests for the kernel-bridge hardening that survived the FlClash UI migration.

These are static contract tests: they run on any CI image without Go, the NDK or
an Android device, and they fail the moment one of the runtime fixes is regressed
by a regenerated file or an over-eager refactor. Symbol equality is covered by
symbol_audit.py; this file covers *behavioural intent*.

What is tested, and where it lives now
--------------------------------------
The kernel is still driven from Kotlin, never from Dart. After the FlClash UI
migration the path is `com.follow.clash.plugins.ServicePlugin` → `ThroneCore` →
`ThroneServiceController`, and the FFI/Dart half of the old bridge
(`flutter/lib/core/kernel_service.dart`, `kernel_worker.dart`, `box.dart`) was
deleted with the rest of the B-box UI. The invariants below were therefore
re-anchored to the files that carry them today:

  * the Go side of the C ABI (panic fences, handle table, one-crossing status
    snapshot, the tun-spec JSON guards) — unchanged, the same files as before;
  * the Java/Kotlin half that owns the tun (`VpnService`, `BaseService`,
    `BboxCorePlatform`, `BboxKernel`, `CoreConfigs`);
  * the channel/lifecycle half (`ServicePlugin`, `ThroneServiceController`), the
    replacement for the deleted `service.start` / service-ready contract.

Assertions whose subject no longer exists are recorded in RETIRED rather than
silently deleted, so a reader can tell "was removed with the migration" from
"was never checked".

Run:  python3 tools/diagnostics/ffi_regression_test.py
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "buildScript" / "core-patch" / "core" / "mobile"
APP = ROOT / "app" / "src" / "main" / "java"
PLUGINS = APP / "com" / "follow" / "clash" / "plugins"
COREHOST = APP / "io" / "throne" / "bbox" / "corehost"
BRIDGE = APP / "io" / "throne" / "bbox" / "bridge"
BG = APP / "io" / "nekohasekai" / "sagernet" / "bg"

# Assertions retired with the FlClash UI migration. Each names the deleted file
# the test used to read, so the coverage gap stays visible in review.
RETIRED = {
    "ui_isolate_never_opens_the_ffi_library":
        "kernel_service.dart / kernel_worker.dart are gone; nothing in Dart opens libthrone.so",
    "temporary_wrappers_are_released_explicitly":
        "kernel_worker.dart is gone; there are no Dart-side handles to release",
    "startup_failure_is_visible_to_the_ui":
        "box.dart is gone; ThroneCore answers through the Core protocol instead",
    "lost_core_is_detected_and_recovered":
        "kernel_worker.dart / kernel_service.dart are gone; recovery moved to the UI layer",
    "worker_commands_cover_every_kernel_operation":
        "box.dart's KernelCommand switch is gone with the FFI driver",
    "service_start_waits_for_the_vpn_service":
        "ThroneBoxBridge.kt is gone; see test_service_plugin_reports_start_and_stop_with_a_revision",
    "set_mode_refreshes_the_pushed_dashboard":
        "BboxBridge is gone; see test_core_protocol_update_persists_the_outbound_mode",
    "dashboard_wire_reads_the_stored_mode":
        "BboxBridge.dashboardWire is gone; nothing caches the mode for a push any more",
}


def export_body(source: str, name: str) -> str:
    match = re.search(rf"^//export {name}\s*$\n^func {name}\(.*?^\}}", source, re.S | re.M)
    if not match:
        raise AssertionError(f"missing export body: {name}")
    return match.group(0)


class GoBridgeHardeningTests(unittest.TestCase):
    """The Go half of the C ABI: the same files and guarantees as before the migration."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.calls = (PATCH / "bridge_calls.go").read_text(encoding="utf-8")
        cls.runtime = (PATCH / "bridge_runtime.go").read_text(encoding="utf-8")
        cls.dartbridge = (PATCH / "dartbridge.go").read_text(encoding="utf-8")

    def test_panics_cannot_cross_cgo(self) -> None:
        for name, source in (("calls", self.calls), ("runtime", self.runtime),
                             ("dartbridge", self.dartbridge)):
            self.assertNotRegex(source, r"\bpanic\(", f"{name} can still abort the process")
        self.assertIn("func guardExport(name string)", self.calls)
        self.assertIn("func initDartApi(api unsafe.Pointer) error", self.dartbridge)

    def test_handle_table_is_observable_and_releasable(self) -> None:
        self.assertIn("handleCreated++", self.calls)
        self.assertIn("handleReleased++", self.calls)
        self.assertIn("handleWarnThreshold", self.calls)
        self.assertIn("throne_handle_stats", self.calls)
        close = export_body(self.calls, "throne_Instance_close")
        self.assertIn("throne_handle_release(handle)", close,
                      "closing an Instance must drop its handle")

    def test_status_snapshot_is_one_crossing_without_a_handle(self) -> None:
        snap = export_body(self.runtime, "throne_status_snapshot")
        self.assertNotIn("marshal_handle", snap)
        for field in ("memory", "goroutines", "connectionsIn", "connectionsOut",
                      "uplink", "downlink", "uplinkTotal", "downlinkTotal"):
            self.assertIn(f'"{field}"', snap)
        self.assertIn('sendEvent("status", snap)', snap,
                      "the UI is driven by a pushed event, not by a poll result")

    def test_status_snapshot_survives_a_panic_with_an_alive_marker(self) -> None:
        """A racing read is not a dead kernel: an empty answer used to restart it."""
        snap = export_body(self.runtime, "throne_status_snapshot")
        self.assertIn('out = C.CString(`{"alive":1}`)', snap,
                      "a panicking status read must answer 'alive, numbers unavailable'")

    def test_tun_spec_json_tolerates_a_disabled_http_proxy(self) -> None:
        """GetHTTPProxyServer() dereferences the nil TunPlatformOptions.HTTPProxy.

        Calling the proxy getters unconditionally panicked inside
        throne_TunOptions_toJSON, so the spec reached VpnService empty and every
        start died with "configure tun interface: bridge: platform callback
        failed" (really: JSONException "End of input at character 0").
        """
        self.assertIn("if httpProxy := o.IsHTTPProxyEnabled(); httpProxy {", self.runtime,
                      "the HTTP proxy getters must stay behind the enabled guard")
        self.assertNotIn('dto["httpProxyServer"] = o.GetHTTPProxyServer()\n\tdto["httpProxyServerPort"]',
                         self.runtime,
                         "unguarded GetHTTPProxyServer() panics when the option is off")
        # The guarded branch must still report the full spec when it is on.
        for key in ('dto["httpProxyEnabled"] = true', 'dto["httpProxyServer"] = ""',
                    'dto["httpProxyServerPort"] = int32(0)', 'dto["httpProxyBypassDomain"] = []string{}'):
            self.assertIn(key, self.runtime, f"missing proxy field default: {key}")

    def test_tun_spec_json_marshals_every_builder_field(self) -> None:
        """VpnService.Builder needs the same fields the old gobind path fed it."""
        start = self.runtime.index("func throne_TunOptions_toJSON")
        body = self.runtime[start:self.runtime.index("var _ = unsafe.Pointer(nil)", start)]
        for field in ("mtu", "autoRoute", "inet4Address", "inet6Address", "inet4RouteAddress",
                      "inet6RouteAddress", "inet4RouteExcludeAddress", "inet6RouteExcludeAddress",
                      "inet4RouteRange", "inet6RouteRange", "includePackage", "excludePackage",
                      "dnsMode", "dnsServerAddress"):
            self.assertIn(f'"{field}"', body, f"tun spec is missing {field}")


class AndroidBridgeHardeningTests(unittest.TestCase):
    """The Java/Kotlin half that owns the tun and the foreground service."""

    def test_ffi_path_registers_vpn_service_before_open_tun(self) -> None:
        """The FFI start skips startProcesses(), so openTun would see a null service."""
        base = (BG / "BaseService.kt").read_text(encoding="utf-8")
        platform = (BRIDGE / "BboxCorePlatform.kt").read_text(encoding="utf-8")
        self.assertIn("DataStore.vpnService ?: run", platform,
                      "openTun must still depend on the registered VpnService")
        self.assertIn("openTun without a live VpnService", platform,
                      "a missing VpnService must be logged instead of failing silently")
        start = base.index("fun startProxy()")
        ffi_return = base.index("BboxKernel.ffiMode", start)
        self.assertIn("if (this is VpnService) DataStore.vpnService = this",
                      base[start:ffi_return],
                      "startProxy must register the VpnService before the FFI early return")

    def test_stop_releases_the_cached_tun_descriptor(self) -> None:
        """The kernel caches the fd from throne_start_tun and reuses it.

        Nothing called Core.stopTun(), so a stop left the cached descriptor behind
        and the next start skipped establishing the interface: no tun0 and no VPN
        network while the dashboard still said Running.
        """
        vpn = (BG / "VpnService.kt").read_text(encoding="utf-8")
        kill = vpn.index("override suspend fun killProcesses()")
        body = vpn[kill:vpn.index("override fun onBind", kill)]
        self.assertIn("Core.stopTun()", body,
                      "killProcesses must drop the cached tun descriptor")
        destroy = vpn.index("override fun onDestroy()")
        self.assertIn("Core.stopTun()", vpn[destroy:destroy + 500],
                      "a service torn down without killProcesses must drop it too")

    def test_outbound_mode_reaches_the_route_input(self) -> None:
        """BboxMode is the only mode switch, and the config generator must consult it.

        `BboxKernel.setMode` used to write the mode without refreshing the pushed
        dashboard, so the chips snapped back. The push is gone (the FlClash UI reads
        the mode through the Core protocol), but the half of that fix a user
        notices — the stored mode actually shaping the generated routing — is
        still here.
        """
        core_configs = (BG / "proto" / "CoreConfigs.kt").read_text(encoding="utf-8")
        self.assertIn("BboxRuntime.routingInput(", core_configs,
                      "the config generator must apply the stored mode to the route input")
        kernel = (BRIDGE / "BboxKernel.kt").read_text(encoding="utf-8")
        self.assertIn("BboxMode.set(", kernel, "the mode must reach the store")
        runtime = (BRIDGE / "BboxRuntime.kt").read_text(encoding="utf-8")
        self.assertIn("BboxMode.applyTo(base)", runtime,
                      "routingInput must rewrite the profile for Global/Direct")


class CoreProtocolHostTests(unittest.TestCase):
    """The replacement for the old `service.start` contract: FlClash's channels on ThroneCore."""

    def test_service_plugin_reports_start_and_stop_with_a_revision(self) -> None:
        """A stop the user did not ask for must not cancel a newer start.

        This is the invariant the deleted `service.start`/`startServiceAndAwaitTun`
        pair protected, re-anchored: the revision is what makes a racing `stopped`
        report harmless on the Dart side (`Service._commandRevision`).
        """
        plugin = (PLUGINS / "ServicePlugin.kt").read_text(encoding="utf-8")
        for arm in ('"start" ->', '"stop" ->', '"init" ->', '"shutdown" ->',
                    '"getRunTime" ->', '"syncState" ->'):
            self.assertIn(arm, plugin, f"ServicePlugin lost the {arm} arm")
        self.assertIn("commandRevision = call.arguments as? Int", plugin,
                      "start/stop must record the revision the caller asked about")
        self.assertIn("if (!ThroneServiceController.isRunRequested)", plugin,
                      "a stop report is only emitted when nothing is asked to run")
        service_dart = (ROOT / "flutter" / "lib" / "plugins" / "service.dart").read_text(
            encoding="utf-8")
        self.assertIn("if (call.arguments != _commandRevision || !_startRequested)",
                      service_dart,
                      "the Dart side must drop a stale stop report")

    def test_core_channel_runs_requests_off_the_platform_thread(self) -> None:
        """`invokeMethod` answers from a background queue; the handler must not block it."""
        plugin = (PLUGINS / "ServicePlugin.kt").read_text(encoding="utf-8")
        self.assertIn("makeBackgroundTaskQueue()", plugin,
                      "the core channel must keep JSON/Go work off the platform thread")
        self.assertIn("ThroneCore.invokeMethod(data)", plugin)

    def test_core_protocol_update_persists_the_outbound_mode(self) -> None:
        """`config.update {mode}` is the only path the UI has to the mode switch now."""
        core = (COREHOST / "ThroneCore.kt").read_text(encoding="utf-8")
        start = core.index("private suspend fun update(params: JsonObject)")
        update = core[start:core.index("\n    }", start)]
        self.assertIn('params.stringOrNull("mode")', update)
        self.assertIn("BboxMode.set(BboxMode.Mode.of(mode))", update,
                      "the mode in a config.update must reach the store")

    def test_core_answers_unsupported_capabilities_explicitly(self) -> None:
        """An empty answer would read as 'supported and empty' to the UI."""
        core = (COREHOST / "ThroneCore.kt").read_text(encoding="utf-8")
        self.assertIn("unsupported_capability", core)
        self.assertIn("class CapabilityException", core)

    def test_service_controller_confirms_a_stop_before_reporting_it(self) -> None:
        """`Stopped` is a waypoint of a restart; reporting it early kills the UI's state."""
        controller = (COREHOST / "ThroneServiceController.kt").read_text(encoding="utf-8")
        self.assertIn("awaitStoppedConfirmed()", controller)
        self.assertIn("STOP_CONFIRM_MILLIS", controller)
        self.assertIn("fun requestStart()", controller)
        self.assertIn("fun requestStop()", controller)


if __name__ == "__main__":
    unittest.main(verbosity=2)
