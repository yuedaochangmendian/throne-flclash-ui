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
        self.assertIn("_recoverOnce()", self.service)
        self.assertIn("report(StateError('the kernel stopped responding'))", self.service)

    def test_worker_commands_cover_every_kernel_operation(self) -> None:
        for command in ("createInstance", "start", "stop", "setHeartbeat",
                        "warpRegister", "dispose"):
            self.assertIn(f"case KernelCommand.{command}:", self.worker)


if __name__ == "__main__":
    unittest.main(verbosity=2)
