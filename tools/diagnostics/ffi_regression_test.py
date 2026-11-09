#!/usr/bin/env python3
"""Regression tests for the FFI hardening (2026-11-04).

These are static contract tests: they run on any CI image without Go, the NDK
or an Android device, and fail the moment one of the runtime fixes is regressed
by a regenerated file or an over-eager refactor. Architecture-level symbol
equality is covered by symbol_audit.py; this file covers *behavioural intent*.

Run:  python3 tools/diagnostics/ffi_regression_test.py
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "buildScript" / "core-patch" / "core" / "mobile"
CORE = ROOT / "flutter" / "lib" / "core"


def export_body(source: str, name: str) -> str:
    match = re.search(rf"^//export {name}\s*$\n^func {name}\(.*?^\}}", source, re.S | re.M)
    if not match:
        raise AssertionError(f"missing export body: {name}")
    return match.group(0)


class FfiHardeningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.calls = (PATCH / "bridge_calls.go").read_text(encoding="utf-8")
        cls.runtime = (PATCH / "bridge_runtime.go").read_text(encoding="utf-8")
        cls.dartbridge = (PATCH / "dartbridge.go").read_text(encoding="utf-8")
        cls.service = (CORE / "kernel_service.dart").read_text(encoding="utf-8")
        cls.worker = (CORE / "kernel_worker.dart").read_text(encoding="utf-8")
        cls.box = (ROOT / "flutter" / "lib" / "box.dart").read_text(encoding="utf-8")

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

    def test_ui_isolate_never_opens_the_ffi_library(self) -> None:
        self.assertNotIn("Isolate.run", self.service)
        self.assertNotIn("DynamicLibrary.open", self.service)
        self.assertIn("KernelWorker.spawn()", self.service)
        self.assertIn("ThroneFFI(DynamicLibrary.open('libthrone.so'))", self.worker)

    def test_temporary_wrappers_are_released_explicitly(self) -> None:
        for call in ("options.release()", "current.release()", "iterator?.release()",
                     "identity?.release()", "request.release()"):
            self.assertIn(call, self.worker, f"missing explicit release: {call}")

    def test_startup_failure_is_visible_to_the_ui(self) -> None:
        init = self.box.index("await kernel.initialize();")
        catch = self.box.find("startupError = describe(error);", init)
        self.assertGreater(catch, init,
                           "kernel.initialize() must be inside a try that sets startupError")

    def test_lost_core_is_detected_and_recovered(self) -> None:
        self.assertIn("'type': 'lost'", self.worker)
        self.assertIn("throneStatusSnapshot(ffi, current.handle)", self.worker)
        # A status read that fails is not a dead core: the cheap liveness probe
        # must be asked before a miss is counted, or a busy box gets restarted.
        self.assertIn("throne_Instance_alive(current.handle)", self.worker)
        self.assertIn("_recoverOnce()", self.service)
        self.assertIn("the kernel stopped responding", self.service)

    def test_worker_commands_cover_every_kernel_operation(self) -> None:
        for command in ("createInstance", "start", "stop", "setHeartbeat",
                        "warpRegister", "dispose"):
            self.assertIn(f"case KernelCommand.{command}:", self.worker)

    def test_ffi_path_registers_vpn_service_before_open_tun(self) -> None:
        """The FFI start skips startProcesses(), so openTun would see a null service."""
        base = (ROOT / "app" / "src" / "main" / "java" / "io" / "nekohasekai" /
                "sagernet" / "bg" / "BaseService.kt").read_text(encoding="utf-8")
        platform = (ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" /
                    "bridge" / "BboxCorePlatform.kt").read_text(encoding="utf-8")
        self.assertIn("DataStore.vpnService ?: run", platform,
                      "openTun must still depend on the registered VpnService")
        self.assertIn("openTun without a live VpnService", platform,
                      "a missing VpnService must be logged instead of failing silently")
        start = base.index("fun startProxy()")
        ffi_return = base.index("BboxKernel.ffiMode", start)
        self.assertIn("if (this is VpnService) DataStore.vpnService = this",
                      base[start:ffi_return],
                      "startProxy must register the VpnService before the FFI early return")

    def test_service_start_waits_for_the_vpn_service(self) -> None:
        """`service.start` only posted an intent, so Dart's FFI start raced the service.

        The channel answer must come after the live VpnService exists; otherwise
        the core's openTun runs first and the start dies with
        "configure tun interface: bridge: platform callback failed".
        """
        bridge = (ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" /
                  "flutter" / "ThroneBoxBridge.kt").read_text(encoding="utf-8")
        self.assertIn('"service.start" -> result.respond {', bridge,
                      "service.start must answer only after the service is ready")
        self.assertNotIn('"service.start" -> {\n                    if (!DataStore.serviceState.canStop) SagerNet.startService()\n                    result.success(null)\n                }',
                         bridge,
                         "service.start must not answer before the service exists")
        wait = bridge.index("private suspend fun startServiceAndAwaitTun()")
        body = bridge[wait:bridge.index("override fun onMethodCall", wait)]
        self.assertIn("SagerNet.startService()", body)
        self.assertIn("while (DataStore.vpnService == null)", body)
        self.assertIn("SERVICE_READY_TIMEOUT_MS", body,
                      "the wait needs a timeout so a broken start fails loudly")
        self.assertIn("Key.MODE_VPN", body,
                      "the tun only exists in VPN mode; proxy mode must not wait")


    def test_tun_spec_json_tolerates_a_disabled_http_proxy(self) -> None:
        """GetHTTPProxyServer() dereferences the nil TunPlatformOptions.HTTPProxy.

        Calling the proxy getters unconditionally panicked inside
        throne_TunOptions_toJSON, so the spec reached VpnService empty and every
        start died with "configure tun interface: bridge: platform callback
        failed" (really: JSONException "End of input at character 0").
        """
        runtime = (ROOT / "buildScript" / "core-patch" / "core" / "mobile" /
                   "bridge_runtime.go").read_text(encoding="utf-8")
        self.assertIn("if httpProxy := o.IsHTTPProxyEnabled(); httpProxy {", runtime,
                      "the HTTP proxy getters must stay behind the enabled guard")
        self.assertNotIn('dto["httpProxyServer"] = o.GetHTTPProxyServer()\n\tdto["httpProxyServerPort"]',
                         runtime,
                         "unguarded GetHTTPProxyServer() panics when the option is off")
        # The guarded branch must still report the full spec when it is on.
        for key in ('dto["httpProxyEnabled"] = true', 'dto["httpProxyServer"] = ""',
                    'dto["httpProxyServerPort"] = int32(0)', 'dto["httpProxyBypassDomain"] = []string{}'):
            self.assertIn(key, runtime, f"missing proxy field default: {key}")

    def test_tun_spec_json_marshals_every_builder_field(self) -> None:
        """VpnService.Builder needs the same fields the old gobind path fed it."""
        runtime = (ROOT / "buildScript" / "core-patch" / "core" / "mobile" /
                   "bridge_runtime.go").read_text(encoding="utf-8")
        start = runtime.index("func throne_TunOptions_toJSON")
        body = runtime[start:runtime.index("var _ = unsafe.Pointer(nil)", start)]
        for field in ("mtu", "autoRoute", "inet4Address", "inet6Address", "inet4RouteAddress",
                      "inet6RouteAddress", "inet4RouteExcludeAddress", "inet6RouteExcludeAddress",
                      "inet4RouteRange", "inet6RouteRange", "includePackage", "excludePackage",
                      "dnsMode", "dnsServerAddress"):
            self.assertIn(f'"{field}"', body, f"tun spec is missing {field}")


    def test_stop_releases_the_cached_tun_descriptor(self) -> None:
        """The kernel caches the fd from throne_start_tun and reuses it.

        Nothing called Core.stopTun(), so a stop left the cached descriptor behind
        and the next start skipped establishing the interface: no tun0 and no VPN
        network while the dashboard still said Running.
        """
        vpn = (ROOT / "app" / "src" / "main" / "java" / "io" / "nekohasekai" /
               "sagernet" / "bg" / "VpnService.kt").read_text(encoding="utf-8")
        kill = vpn.index("override suspend fun killProcesses()")
        body = vpn[kill:vpn.index("override fun onBind", kill)]
        self.assertIn("Core.stopTun()", body,
                      "killProcesses must drop the cached tun descriptor")
        destroy = vpn.index("override fun onDestroy()")
        self.assertIn("Core.stopTun()", vpn[destroy:destroy + 500],
                      "a service torn down without killProcesses must drop it too")


    def test_set_mode_refreshes_the_pushed_dashboard(self) -> None:
        """The FFI mode switch persisted the mode but never refreshed the UI state.

        BboxBridge caches dashboard.mode and the bridge re-publishes that cache on
        every change. BboxKernel.setMode only wrote the store, so the next push
        carried the previous mode, Dart applied it and the chips snapped back: the
        switch looked dead even though the store already held the new value.
        """
        kernel = (ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" /
                  "bridge" / "BboxKernel.kt").read_text(encoding="utf-8")
        start = kernel.index("fun setMode(mode: String)")
        body = kernel[start:kernel.index("\n    }", start)]
        self.assertIn("BboxMode.set(", body, "the mode must reach the store")
        self.assertIn("BboxBridge.scheduleRefresh(immediate = true)", body,
                      "without a refresh the cached dashboard keeps the old mode")

    def test_dashboard_wire_reads_the_stored_mode(self) -> None:
        """The wire must never echo a cached mode back to Dart.

        Even with the refresh above, a push can race the catalog reload. Reading the
        store makes every emission self-consistent, so the highlight cannot revert.
        """
        bridge = (ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" /
                  "flutter" / "ThroneBoxBridge.kt").read_text(encoding="utf-8")
        start = bridge.index("private fun dashboardWire(")
        body = bridge[start:bridge.index("private fun profilesWire", start)]
        self.assertIn('"mode" to BboxMode.get().id', body,
                      "dashboardWire must read the stored mode, not dashboard.mode")
        self.assertNotIn('"mode" to dashboard.mode', body)
        self.assertIn("import io.flrone.bridge.BboxMode", bridge)


if __name__ == "__main__":
    unittest.main(verbosity=2)
