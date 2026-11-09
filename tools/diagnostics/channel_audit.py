"""MethodChannel contract audit for the B-box bridge.

Cross-checks, statically, the two ends of the bridge that `flutter analyze` and
the Kotlin compiler cannot see (the contract lives in string literals):

  - Dart -> Kotlin: every method the UI invokes (`box.call('…')` / `box.act('…')`,
    dotted or bare inside BoxController) must have a `when(call.method)` handler
    in ThroneBoxBridge.kt — unless the method belongs to a capability that is
    switched off in Capabilities.kt (those pages ship unreachable by design;
    flipping a capability to true without adding its handlers fails this audit)
  - Kotlin -> Dart: every event the host emits (`emit("…", …)`) must be consumed
    by a `case '…'` in the Dart event dispatcher (flutter/lib/box.dart), and the
    MethodChannel names must exist on both ends
  - dispatch sites whose method is not a literal (ternaries, switch arms, widget
    arguments) are held to a declared allowlist in DYNAMIC_SITES — exact names and
    dot-terminated prefixes only — a new site or an undeclared name fails; every
    declared name must also have a handler
  - handlers with no caller are listed (with --verbose) as dead-weight candidates

Run from the repository root:
    uv run tools/diagnostics/channel_audit.py [--verbose]

Exit code 0 when every call has a handler and every event a consumer, 1 otherwise.

Assumptions and maintenance
---------------------------
This is a deliberately shallow, regex-based cross-check, not a parser. Two
hand-maintained assumptions keep it working; both are fragile and are the first
things to suspect when the audit reports a false positive or a false negative:

  1. DYNAMIC_SITES is a manual allowlist of dispatch sites whose method name is
     not a string literal (ternaries, switch arms, widget-driven calls), keyed by
     source file, with exact names or dot-terminated prefixes. It is not derived
     from the Dart AST. Adding a new dynamic dispatch site anywhere else makes the
     audit fail until that site and the names it can produce are declared here;
     every declared name must also have a Kotlin handler. When the UI changes,
     review this table and keep the declared names in sync with the code.
  2. kotlin_handlers() bounds the `when (call.method)` block by the next member
     function, which it assumes sits at exactly four spaces of indentation (a
     normal Kotlin class-body `fun`). A nested `fun` at that same depth, or a
     class reformatted to a different indent, truncates the slice. The failure is
     deliberately fail-closed: handlers after such a boundary surface as missing,
     never silently excused. See the arm_indent note in kotlin_handlers() for the
     related column assumption on the `when` arms.

Both assumptions are documented rather than generalised here on purpose: the
audit is a CI gate, so rewriting the parsing logic in place would risk weakening
it. If either assumption stops matching the code, fix the assumption and the
table explicitly, then re-run the audit.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FLUTTER_LIB = REPO_ROOT / "flutter" / "lib"
BRIDGE = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "flutter" / "ThroneBoxBridge.kt"
BRIDGE_DIR = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone"
CAPABILITIES = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "Capabilities.kt"
DART_DISPATCH = FLUTTER_LIB / "box.dart"

# Bridge dispatches only: the receiver is a box-ish identifier (`box`, `_box!`,
# `context.box`), so an unrelated `.call(` on a callback field never matches.
# `?.call(` on a Dart Callable is not a dispatch and the `?` lookbehind keeps it
# out; whitespace before the paren is allowed (`box.call ('…')`). The bare form
# (`call('…')` inside BoxController) is matched separately.
RECEIVER = r"\w*box\s*!?\??\s*\.\s*(?:call|act)"
BARE = r"(?<![\w?.])(?:call|act)"
CALL_RE = re.compile(rf"(?<!\?)(?:{RECEIVER}|{BARE})\s*\(\s*'([a-zA-Z][a-zA-Z0-9_.:]*)'", re.IGNORECASE)
# An interpolated method name (`act('${widget.kind}.submit')`) is a dispatch the
# literal regex cannot name. The second alternative is a ZERO-WIDTH lookahead right
# after the paren: a consuming match would backtrack to the last `$` and leave
# first_argument() starting mid-string, silently disabling the tail check below.
DYNAMIC_CALL_RE = re.compile(
    rf"(?<!\?)(?:{RECEIVER}|{BARE})\s*\(\s*(?!['\s)])"
    rf"|(?<!\?)(?:{RECEIVER}|{BARE})\s*\(\s*(?='(?:[^'\\]|\\.)*\$)",
    re.IGNORECASE)
KOTLIN_METHOD_RE = re.compile(r'"([a-zA-Z][a-zA-Z0-9_.:]*)"\s*->')
EMIT_RE = re.compile(r'\bemit\(\s*"([a-zA-Z][a-zA-Z0-9_]*)"')
DART_CASE_RE = re.compile(r"case\s+'([a-zA-Z][a-zA-Z0-9_.:]*)'")
DART_CHANNEL_RE = re.compile(r"(?:Method|Event)Channel\(\s*'([^']+)'")
# Read channel names from the constructors on both ends rather than hard-coding
# an organisation prefix: renaming the bridge namespace must not break this gate.
KOTLIN_CHANNEL_RE = re.compile(r'(?:Method|Event)Channel\([^)]*?"([^"]+)"')
CAPABILITY_RE = re.compile(r'"([a-zA-Z]+)"\s+to\s+(true|false)')

# Handlers are dotted (`word.word…`) with the single historical exception of
# `ready`; anything else a `"…" ->` match picks up inside the when block (nested
# data mappings like "Stopping", "directDns") is not a handler.
METHOD_NAME_RE = re.compile(r"^[a-z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+$|^ready$")

# Methods invoked through a disabled capability's UI. Key = Capabilities.kt key,
# values = the bridge-method prefixes that belong to it. The vendored B-box pages
# behind `false` call these, the bridge answers none of them — expected absence.
# Turning a capability on without landing its handlers fails this audit. Exact
# names (`share.send`) vouch exactly; dot-terminated entries vouch a prefix.
CAPABILITY_PREFIXES: dict[str, set[str]] = {
    "terminal": {"ssh.", "terminal."},
    "capture": {"capture."},
    "remote": {"remote."},
    "reports": {"reports."},
    "stun": {"stun."},
    "quality": {"quality."},
    "taildrop": {"taildrop.", "share.send", "share.discard"},  # share.text is live regardless of Taildrop
    "endpoints": {"tailscale.", "usb.", "openvpn.", "openconnect.", "usbip."},
}

# Dynamic dispatch sites (ternaries, switch arms, widget-driven methods) with
# their literals; a name ending in `.` matches every method under it, anything
# else matches exactly. Keep in sync with the code — a new dynamic site anywhere
# else fails the audit, and every declared name must have a handler.
DYNAMIC_SITES: dict[str, set[str]] = {
    "flutter/lib/box.dart": {"dashboard.memory.visible", "logs.logcat.visible", "groups.testSession.visible", "logs.visible"},
    "flutter/lib/components/capture_poll.dart": {"capture."},  # widget.method, capability-gated page
    "flutter/lib/components/status_panel.dart": {"service.start", "service.stop"},
    "flutter/lib/pages/backup.dart": {"webdav.read", "backup.read"},
    "flutter/lib/pages/authentication.dart": {
        f"{kind}.{action}" for kind in ("tailscale", "openconnect", "openvpn", "usbip") for action in ("cancel", "submit")
    },  # '${widget.kind}.{cancel,submit}', capability-gated page
    "flutter/lib/pages/diagnostics.dart": {"quality.start", "quality.stop", "quality.confirm", "quality.dismiss", "stun.start", "stun.stop"},
    "flutter/lib/pages/logs.dart": {"logs.clear", "logs.logcat.clear"},
    "flutter/lib/pages/requests.dart": {"capture."},  # passthrough, capability-gated page
    "flutter/lib/pages/taildrop.dart": {"taildrop.dismissSend", "taildrop.cancelSend"},
}

# Generated code is not dispatch-site territory; only its literal calls count.
DYNAMIC_EXEMPT = ("flutter/lib/ui/generated/",)


def covered(method: str, entries: set[str]) -> bool:
    """Exact names vouch exactly; a name ending in a dot vouches its prefix."""
    return any(method == entry or (entry.endswith(".") and method.startswith(entry)) for entry in entries)


def dart_calls() -> tuple[dict[str, list[str]], list[str]]:
    callers: dict[str, list[str]] = {}
    dynamic: list[str] = []
    for path in sorted(FLUTTER_LIB.rglob("*.dart")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        text = path.read_text(encoding="utf-8")
        for match in CALL_RE.finditer(text):
            callers.setdefault(match.group(1), []).append(rel)
        if rel.startswith(DYNAMIC_EXEMPT):
            continue
        for match in DYNAMIC_CALL_RE.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            dynamic.append(f"{rel}:{line}")
    return callers, dynamic


def kotlin_handlers() -> set[str]:
    text = BRIDGE.read_text(encoding="utf-8")
    start = text.find("when (call.method)")
    if start < 0:
        return set()
    # The when block runs to the next member function: brace matching cannot be used
    # here, because Kotlin's nested string interpolations ("${if (x) "a" else "b"}")
    # defeat every regular-expression counter. The boundary assumes member functions
    # sit at exactly four spaces of indentation — a nested `fun` at that depth inside
    # the when block would truncate the slice (fail-closed: handlers after it would
    # surface as missing, never silently excused). Without any following member
    # function the boundary is unknown: fail loudly rather than slice to EOF, where
    # later `"dotted" ->` mappings would leak in as phantom handlers.
    tail = text[start:]
    next_fun = re.search(r"\n    (?:private |internal |override )?(?:suspend )?fun ", tail)
    if next_fun is None:
        raise SystemExit("channel audit: no member function after `when (call.method)` — "
                         "cannot bound the handler block; adjust kotlin_handlers()")
    end = start + next_fun.start()
    # Arms sit one level under the `when`'s own indentation; anchoring the match to
    # that column keeps a nested `when (state) { "dotted" -> … }` from counting as
    # a handler of the outer dispatch.
    when_line = text[:start].rsplit("\n", 1)[-1]
    # arm_indent applies only to this one, conventionally formatted Kotlin block:
    # the `when` line sits at N spaces and its arms at N + 4 (four-space class
    # indentation). Tabs, a different indent width, or arms on the `when` line
    # shift the column matched below and make handlers look missing (fail-closed,
    # as the bounding comment above describes). This is the documented assumption,
    # not a general Kotlin parser; keep the two assumptions in the module docstring
    # in mind before changing this arithmetic.
    arm_indent = len(when_line) - len(when_line.lstrip()) + 4
    arms = re.finditer(rf"^ {{{arm_indent}}}\"([a-zA-Z][a-zA-Z0-9_.:]*)\"\s*->", text[start:end], flags=re.M)
    return {name for name in (match.group(1) for match in arms) if METHOD_NAME_RE.match(name)}


def disabled_capabilities() -> set[str]:
    text = CAPABILITIES.read_text(encoding="utf-8")
    return {key for key, value in CAPABILITY_RE.findall(text) if value == "false"}


def expected_absent(disabled: set[str]) -> set[str]:
    absent: set[str] = set()
    for capability in disabled:
        absent |= CAPABILITY_PREFIXES.get(capability, set())
    return absent


def emitted_events() -> set[str]:
    return set(EMIT_RE.findall(BRIDGE.read_text(encoding="utf-8")))


def consumed_events() -> set[str]:
    return set(DART_CASE_RE.findall(DART_DISPATCH.read_text(encoding="utf-8")))


def dart_channels() -> set[str]:
    return set(DART_CHANNEL_RE.findall(DART_DISPATCH.read_text(encoding="utf-8")))


def kotlin_channels() -> set[str]:
    found = set()
    for path in BRIDGE_DIR.rglob("*.kt"):
        found |= set(KOTLIN_CHANNEL_RE.findall(path.read_text(encoding="utf-8")))
    return found


def first_argument(text: str, open_paren: int) -> str:
    depth = 0
    for index in range(open_paren, len(text)):
        char = text[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                return text[open_paren:index]
            depth -= 1
        elif char == "," and depth == 0:
            return text[open_paren:index]
    return text[open_paren:]


def allowed_name(method: str, literals: set[str], absent_prefixes: set[str]) -> bool:
    return covered(method, literals) or covered(method, absent_prefixes)


def site_allowed(site: str, absent_prefixes: set[str]) -> bool:
    file, _, line = site.partition(":")
    literals = DYNAMIC_SITES.get(Path(file).as_posix())
    if literals is None:
        return False
    text = (REPO_ROOT / file).read_text(encoding="utf-8")
    matches = [m for m in DYNAMIC_CALL_RE.finditer(text)
               if text.count("\n", 0, m.start()) + 1 == int(line)]
    if not matches:
        return False
    # Every dispatch on the line must be allowed; one bad call must not hide
    # behind a good neighbour.
    verdicts = []
    for match in matches:
        first = first_argument(text, match.end())
        if "$" in first:
            # An interpolated name (`'${widget.kind}.cancel'`): vouch through the
            # constant tail after the last interpolation, which the declared set
            # must end with — the tail segment, not just any suffix.
            tail = re.search(r"\}([a-zA-Z0-9_.]*)'?\"?\)?\s*,?\s*$", first)
            if not tail or not tail.group(1):
                verdicts.append(False)
                continue
            segment = f".{tail.group(1).lstrip('.')}"
            verdicts.append(any(name.endswith(segment) for name in literals if not name.endswith(".")))
            continue
        # A conditional dispatch offers its branch results as the method names; a
        # plain quoted name must be declared; a bare identifier/member chain is
        # widget-driven and gated by its page's capability.
        branches = [a or b for a, b in re.findall(r"\?\s*'([^']+)'|:\s*'([^']+)'", first)]
        if not branches:
            branches = [a or b for a, b in
                        re.findall(r"'([a-zA-Z][a-zA-Z0-9_.:]*)'|\"([a-zA-Z][a-zA-Z0-9_.:]*)\"", first)]
        if not branches:
            verdicts.append(True)
            continue
        verdicts.append(all(allowed_name(method, literals, absent_prefixes) for method in branches))
    return all(verdicts)


def ffi_id_contract_failures() -> list[str]:
    """Prevent a recurrence of the "profile 0 is gone" startup failure.

    The Flutter preference store holds appearance settings only; the native DB
    (DataStore.selectedProxy) owns the selected ProxyEntity, and the dashboard's
    selectedProfileId is a *group* id for display. Mining the wrong map used to
    send `config.build {id: 0}` on every start.
    """
    problems: list[str] = []
    service = (FLUTTER_LIB / "core" / "kernel_service.dart").read_text(encoding="utf-8")
    args = re.search(r"Json configBuildArgs\(\)\s*=>\s*(.*?);", service, re.S)
    if not args:
        problems.append("configBuildArgs() is missing")
    elif re.search(r"['\"]id['\"]", args.group(1)):
        problems.append("configBuildArgs() sends an 'id'; the native side must resolve DataStore.selectedProxy")
    if re.search(r"preferences\[['\"](?:selectedProxy|profileId)['\"]\]", service):
        problems.append("kernel_service.dart mines Flutter preferences for a proxy id")
    if re.search(r"\bIsolate\.run\b", service):
        problems.append("kernel_service.dart still opens a fresh isolate per FFI call")

    kernel = (REPO_ROOT / "app/src/main/java/io/flrone/bridge/BboxKernel.kt").read_text(encoding="utf-8")
    if not re.search(r"fun buildStartOptions\(\)", kernel):
        problems.append("BboxKernel.buildStartOptions must resolve the profile itself (no id parameter)")
    if "DataStore.selectedProxy" not in kernel:
        problems.append("BboxKernel no longer falls back to DataStore.selectedProxy")
    if re.search(r'config\.build[\s\S]{0,300}call\.argument<Int>\("id"\)',
                 BRIDGE.read_text(encoding="utf-8")):
        problems.append("ThroneBoxBridge.config.build still forwards a guessed id")
    return problems


def platform_value_contract_failures() -> list[str]:
    """Prevent the `_Map<Object?, Object?> is not a Map<String, dynamic>` crash.

    StandardMessageCodec decodes native maps into `_Map<Object?, Object?>`.
    Casting those directly to `Json` used to abort `config.build` and
    `config.warpParams` on every start / WARP registration. The fix belongs at
    the channel boundary (BoxController.call + the EventChannel stream), with
    checked conversions anywhere an isolate bounces a map back.
    """
    problems: list[str] = []
    box = (FLUTTER_LIB / "box.dart").read_text(encoding="utf-8")
    helper = FLUTTER_LIB / "core" / "platform_value.dart"
    service = FLUTTER_LIB / "core" / "kernel_service.dart"
    worker = FLUTTER_LIB / "core" / "kernel_worker.dart"

    if not helper.exists():
        problems.append("flutter/lib/core/platform_value.dart is missing")
    else:
        text = helper.read_text(encoding="utf-8")
        if not re.search(r"Object\?\s+normalizePlatformValue\(", text):
            problems.append("normalizePlatformValue() is missing")
        if "value is TypedData" not in text:
            problems.append("normalizePlatformValue() must preserve typed data (app icons)")
        if not re.search(r"value is Map[\s\S]{0,200}normalizePlatformValue", text):
            problems.append("normalizePlatformValue() must recurse into nested maps")

    call = re.search(r"Future<dynamic> call\(String method[\s\S]{0,300}?;", box)
    if not call or "normalizePlatformValue" not in call.group(0):
        problems.append("BoxController.call must normalize method-channel replies")
    if not re.search(r"_events\s*=[\s\S]{0,250}normalizePlatformValue", box):
        problems.append("the EventChannel stream must normalize its payloads")
    if "import 'core/platform_value.dart';" not in box:
        problems.append("box.dart must import the normalization helper")

    # Generated bindings (throne_ffi.dart) legitimately cast json.decode output;
    # hand-written runtime code must never cast a channel/isolate value to Json.
    for path in (service, worker):
        text = path.read_text(encoding="utf-8")
        if re.search(r"\bas\s+(?:Map<String,\s*dynamic>|Json)\b", text):
            problems.append(f"{path.name} casts a platform value directly to Json")
        if "asStringKeyedMap" not in text:
            problems.append(f"{path.name} must use asStringKeyedMap() for wire maps")

    test = REPO_ROOT / "flutter" / "test" / "platform_value_test.dart"
    if not test.exists():
        problems.append("platform_value_test.dart regression suite is missing")
    elif "StandardMessageCodec" not in test.read_text(encoding="utf-8"):
        problems.append("the regression suite must exercise the real codec shape")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--verbose", action="store_true", help="also list handlers with no Dart caller")
    args = parser.parse_args()

    calls, dynamic = dart_calls()
    handlers = kotlin_handlers()
    disabled = disabled_capabilities()
    absent_prefixes = expected_absent(disabled)
    emits = emitted_events()
    consumers = consumed_events()

    missing_handlers = sorted(
        method for method in set(calls) - handlers
        if not covered(method, absent_prefixes)
    )
    missing_consumers = sorted(emits - consumers)
    unknown_dynamic = [site for site in dynamic if not site_allowed(site, absent_prefixes)]
    # A declared dynamic name with no handler is invisible to every check above
    # (its callers are all dynamic): validate the declarations themselves. A
    # declaration only applies when its site file exists in the audited tree.
    dead_declarations = sorted(
        literal for file, literals in DYNAMIC_SITES.items() for literal in literals
        if (REPO_ROOT / file).exists()
        and not covered(literal, handlers) and not covered(literal, absent_prefixes)
    )
    dynamic_known = {method for literals in DYNAMIC_SITES.values() for method in literals if not method.endswith(".")}
    uncalled = sorted(
        handler for handler in handlers - set(calls) - dynamic_known
        if not covered(handler, absent_prefixes)
    )
    missing_channels = sorted(dart_channels() - kotlin_channels())

    print(f"bridge methods: {len(handlers)} handlers, {len(calls)} distinct Dart callers, "
          f"{len(disabled)} capabilities off")
    print(f"events: {len(emits)} emitted, {len(consumers)} consumed; "
          f"channels: {len(dart_channels())} dart, {len(kotlin_channels())} kotlin")

    failed = False
    if missing_handlers:
        failed = True
        print("\nFAIL — Dart calls without a Kotlin handler:")
        for method in missing_handlers:
            print(f"  {method}  (called from {', '.join(sorted(set(calls[method])))})")
    if missing_consumers:
        failed = True
        print("\nFAIL — Kotlin events without a Dart consumer (flutter/lib/box.dart):")
        for event in missing_consumers:
            print(f"  {event}")
    if unknown_dynamic:
        failed = True
        print("\nFAIL — dynamic dispatch sites outside DYNAMIC_SITES (declare them in the script):")
        for site in unknown_dynamic:
            print(f"  {site}")
    if dead_declarations:
        failed = True
        print("\nFAIL — declared dynamic names without a handler (the caller is dynamic,")
        print("so this is the only place the breakage would show):")
        for literal in dead_declarations:
            print(f"  {literal}")
    if missing_channels:
        failed = True
        print("\nFAIL — Dart channels with no Kotlin counterpart:")
        for channel in missing_channels:
            print(f"  {channel}")
    if args.verbose and uncalled:
        print("\nnote — Kotlin handlers with no Dart caller found:")
        for method in uncalled:
            print(f"  {method}")

    id_problems = ffi_id_contract_failures()
    if id_problems:
        failed = True
        print("\nFAIL — FFI profile-id contract:")
        for problem in id_problems:
            print(f"  {problem}")

    wire_problems = platform_value_contract_failures()
    if wire_problems:
        failed = True
        print("\nFAIL — platform value contract:")
        for problem in wire_problems:
            print(f"  {problem}")

    if not failed:
        print("\ncontract OK: every live call has a handler, every event a consumer, "
              "the FFI path never invents a proxy id, and platform values are normalized")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
