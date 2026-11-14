"""MethodChannel contract audit for the FlClash plugin surface this host implements.

`flutter analyze` and the Kotlin compiler cannot see the channel contract: both
ends name methods with string literals, so a rename on one side compiles fine and
fails at runtime as `MissingPluginException` (or worse, a silent no-op).

The audited surface is exactly the hand-written plugin set — FlClash's four
channels, answered by this repository's Kotlin plugins:

    com.follow.clash/app      <-> app/src/main/java/com/follow/clash/plugins/AppPlugin.kt
    com.follow.clash/service  <-> .../ServicePlugin.kt   (lifecycle: start/stop/init/…)
    com.follow.clash/core     <-> .../ServicePlugin.kt   (one method: invokeMethod)
    com.follow.clash/battery  <-> .../BatteryPlugin.kt   (+ /battery/optimization EventChannel)
    com.follow.clash/tile     <-> .../TilePlugin.kt      (Kotlin -> Dart only)

What is checked:

  - the channel prefix is one constant on both ends: `packageName` in
    flutter/lib/common/constant.dart must equal `Components.PACKAGE_NAME`. Both
    sides build every channel name from it, so renaming one alone breaks all of
    them at once with no compile error anywhere;
  - every method Dart invokes on a channel has a `"…" ->` arm in that channel's
    Kotlin plugin;
  - every event the Kotlin plugin pushes at Dart (`invokeMethod("…")`,
    `invokeMethodOnMainThread("…")`, `MethodCall("…", …)`) is consumed by a
    `case '…':` in the paired Dart file;
  - every channel literal appears on both ends (a MethodChannel/EventChannel name
    with no counterpart is a stream that never receives anything);
  - dispatch sites whose method name is not a string literal must be declared in
    DYNAMIC_SITES, keyed by `path:line`.

Deliberately shallow, like every audit in this directory: it is a regex
cross-check over string literals, not a Dart or Kotlin parser. The channel table
below is hand-maintained on purpose — a new channel means a new row, and that is
the moment to re-read this file.

History: until the FlClash UI migration this script audited `io.flrone/box`, the
B-box bridge (`ThroneBoxBridge.kt` + `flutter/lib/box.dart`). Both ends were
deleted with the migration; the channel here is the one that replaced them.

Run from the repository root:
    python3 tools/diagnostics/channel_audit.py [--verbose]

Exit code 0 when every live call has a handler and every event a consumer, 1
otherwise.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FLUTTER_LIB = REPO_ROOT / "flutter" / "lib"
KOTLIN_PLUGINS = REPO_ROOT / "app" / "src" / "main" / "java" / "com" / "follow" / "clash" / "plugins"

# The one prefix both ends must agree on.
DART_CONSTANT = FLUTTER_LIB / "common" / "constant.dart"
KOTLIN_COMPONENTS = REPO_ROOT / "app" / "src" / "main" / "java" / "com" / "follow" / "clash" / "common" / "Components.kt"

# channel suffix -> (Dart file that speaks it, Kotlin plugin that answers it).
# A suffix used by two plugins (`service` and `core` both live in ServicePlugin.kt)
# is listed twice: the handler arms are per-file, and ServicePlugin registers both.
CHANNELS: dict[str, tuple[str, str]] = {
    "app": ("flutter/lib/plugins/app.dart", "AppPlugin.kt"),
    "service": ("flutter/lib/plugins/service.dart", "ServicePlugin.kt"),
    "core": ("flutter/lib/plugins/service.dart", "ServicePlugin.kt"),
    "battery": ("flutter/lib/plugins/battery.dart", "BatteryPlugin.kt"),
    "tile": ("flutter/lib/plugins/tile.dart", "TilePlugin.kt"),
}

# EventChannel names that are not method channels and therefore carry no method
# contract, only a name that must match. Suffix -> (dart, kotlin) as above.
EVENT_CHANNELS: dict[str, tuple[str, str]] = {
    "battery/optimization": ("flutter/lib/plugins/battery.dart", "BatteryPlugin.kt"),
}

# Dispatch sites whose method name is not a literal, keyed `path:line`.
# Keep this empty unless a call site genuinely cannot be written literally; an
# undeclared non-literal site fails the audit so a typo cannot hide behind one.
DYNAMIC_SITES: dict[str, str] = {}

# Only a call on a MethodChannel receiver is a platform dispatch. The receiver is
# the Dart field holding the channel, and every one of them is named for it
# (`methodChannel`, `_coreChannel`, `_methodChannel`), so requiring "channel" in
# the receiver name is what separates `_coreChannel.invokeMethod('init')` from the
# Dart-level Core RPC wrapper `_service!.invokeMethod(method: …)` and from the
# declaration `Future<CoreMethodResponse> invokeMethod(CoreMethodCall call)`.
RECEIVER = r"([A-Za-z_]\w*)\s*\.\s*"
DART_CALL_RE = re.compile(
    RECEIVER + r"invoke(?:Map|List)?Method\s*<[^>]*>\s*\(\s*'([A-Za-z0-9_]+)'",
    re.S,
)
DART_INVOKE_RE = re.compile(RECEIVER + r"invoke(?:Map|List)?Method\b")
DART_CASE_RE = re.compile(r"case\s+'([A-Za-z0-9_]+)'\s*:")
DART_LITERAL_RE = re.compile(r"'(?:\$packageName)/([A-Za-z0-9_/]+)'")


def is_channel_receiver(name: str) -> bool:
    return "channel" in name.lower()

KOTLIN_ARM_RE = re.compile(r'^\s*"([a-zA-Z][A-Za-z0-9_.]*)"\s*->', re.M)
KOTLIN_EMIT_RE = re.compile(
    r'(?:invokeMethodOnMainThread|invokeMethod)\s*\(\s*"([a-zA-Z][A-Za-z0-9_]*)"'
)
KOTLIN_METHOD_CALL_RE = re.compile(r'MethodCall\s*\(\s*"([a-zA-Z][A-Za-z0-9_]*)"')
KOTLIN_LITERAL_RE = re.compile(r'"\$\{Components\.PACKAGE_NAME\}/([A-Za-z0-9_/]+)"')


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def dart_package_name() -> str | None:
    match = re.search(r"const\s+packageName\s*=\s*'([^']+)'", read(DART_CONSTANT))
    return match.group(1) if match else None


def kotlin_package_name() -> str | None:
    match = re.search(r'PACKAGE_NAME\s*=\s*"([^"]+)"', read(KOTLIN_COMPONENTS))
    return match.group(1) if match else None


def dart_calls(relative: str) -> set[str]:
    text = read(REPO_ROOT / relative)
    return {
        match.group(2)
        for match in DART_CALL_RE.finditer(text)
        if is_channel_receiver(match.group(1))
    }


def dart_cases(relative: str) -> set[str]:
    return set(DART_CASE_RE.findall(read(REPO_ROOT / relative)))


def kotlin_arms(plugin: str) -> set[str]:
    return set(KOTLIN_ARM_RE.findall(read(KOTLIN_PLUGINS / plugin)))


def kotlin_emits(plugin: str) -> set[str]:
    text = read(KOTLIN_PLUGINS / plugin)
    return set(KOTLIN_EMIT_RE.findall(text)) | set(KOTLIN_METHOD_CALL_RE.findall(text))


def dart_channel_literals() -> set[str]:
    found: set[str] = set()
    for path in FLUTTER_LIB.rglob("*.dart"):
        found |= set(DART_LITERAL_RE.findall(path.read_text(encoding="utf-8")))
    return found


def kotlin_channel_literals() -> set[str]:
    found: set[str] = set()
    for path in KOTLIN_PLUGINS.rglob("*.kt"):
        found |= set(KOTLIN_LITERAL_RE.findall(path.read_text(encoding="utf-8")))
    return found


def dynamic_call_sites() -> list[str]:
    """Every channel dispatch whose method argument is not a plain quoted literal.

    The receiver must name a channel (see is_channel_receiver), so the Dart-level
    Core RPC wrappers and local method declarations never reach this scan. The
    argument is then classified:

      ``{``            an all-named argument list (no platform dispatch)
      ``ident:``       a named-argument call, likewise
      ``'…'``          a literal, claimed by dart_calls() unless it interpolates
                       (`'${widget.kind}.cancel'`), which no literal regex can name
      anything else    a variable / ternary / switch arm: a dynamic dispatch

    Reported as `path:line` so DYNAMIC_SITES stays greppable.
    """
    sites: list[str] = []
    named_argument = re.compile(r"[A-Za-z_][\w]*\s*:(?!-)")
    for path in sorted(FLUTTER_LIB.rglob("*.dart")):
        text = path.read_text(encoding="utf-8")
        for match in DART_INVOKE_RE.finditer(text):
            if not is_channel_receiver(match.group(1)):
                continue
            cursor = match.end()
            if cursor < len(text) and text[cursor] == "<":
                depth = 0
                while cursor < len(text):
                    if text[cursor] == "<":
                        depth += 1
                    elif text[cursor] == ">":
                        depth -= 1
                        if depth == 0:
                            cursor += 1
                            break
                    cursor += 1
            while cursor < len(text) and text[cursor] in " \t\r\n":
                cursor += 1
            if cursor >= len(text) or text[cursor] != "(":
                continue
            cursor += 1
            while cursor < len(text) and text[cursor] in " \t\r\n":
                cursor += 1
            if cursor >= len(text):
                continue
            tail = text[cursor:]
            head = tail[0]
            if head == "{" or named_argument.match(tail):
                continue
            if head == "'":
                close = 1
                while close < len(tail):
                    if tail[close] == "\\":
                        close += 2
                        continue
                    if tail[close] == "'":
                        break
                    close += 1
                if "$" not in tail[: close + 1]:
                    continue
            sites.append(f"{path.relative_to(REPO_ROOT).as_posix()}:{text.count(chr(10), 0, match.start()) + 1}")
    return sites


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--verbose", action="store_true",
                        help="also list Kotlin handlers with no Dart caller")
    args = parser.parse_args()

    failures: list[str] = []

    dart_prefix = dart_package_name()
    kotlin_prefix = kotlin_package_name()
    if dart_prefix is None:
        failures.append(f"could not read `packageName` from {DART_CONSTANT.relative_to(REPO_ROOT)}")
    if kotlin_prefix is None:
        failures.append(f"could not read PACKAGE_NAME from {KOTLIN_COMPONENTS.relative_to(REPO_ROOT)}")
    if dart_prefix and kotlin_prefix and dart_prefix != kotlin_prefix:
        failures.append(
            f"channel prefix skew: flutter/lib/common/constant.dart says {dart_prefix!r}, "
            f"Components.kt says {kotlin_prefix!r} — every channel name differs"
        )
    if failures:
        for failure in failures:
            print(f"FAIL — {failure}")
        return 1

    total_handlers = 0
    total_calls = 0
    reported_emits = 0
    reported_consumers = 0

    for suffix, (dart_file, plugin) in CHANNELS.items():
        channel = f"{dart_prefix}/{suffix}"
        calls = dart_calls(dart_file)
        arms = kotlin_arms(plugin)
        total_handlers += len(arms)
        total_calls += len(calls)
        missing = sorted(calls - arms)
        if missing:
            failures.append(
                f"{channel}: Dart calls with no Kotlin handler in {plugin}: "
                + ", ".join(missing)
            )
        if args.verbose:
            uncalled = sorted(arms - calls)
            if uncalled:
                print(f"note — {channel}: handlers with no Dart caller: {', '.join(uncalled)}")

    # Kotlin -> Dart. Both directions live in the same plugin files, so pair each
    # plugin with the Dart file that owns the matching channel.
    paired: dict[str, str] = {}
    for suffix, (dart_file, plugin) in CHANNELS.items():
        paired.setdefault(plugin, dart_file)
    for plugin, dart_file in paired.items():
        emits = kotlin_emits(plugin)
        consumers = dart_cases(dart_file)
        reported_emits += len(emits)
        reported_consumers += len(consumers)
        missing = sorted(emits - consumers)
        if missing:
            failures.append(
                f"{plugin} pushes events Dart does not handle in {dart_file}: "
                + ", ".join(missing)
            )

    # Channel names must exist on both ends. `battery/optimization` is an
    # EventChannel on both sides; the rest are MethodChannels.
    dart_names = dart_channel_literals()
    kotlin_names = kotlin_channel_literals()
    expected = set(CHANNELS) | set(EVENT_CHANNELS)
    undeclared_dart = sorted(dart_names - expected)
    undeclared_kotlin = sorted(kotlin_names - expected)
    if undeclared_dart:
        failures.append(
            "Dart names channels this audit does not know (add them to CHANNELS): "
            + ", ".join(undeclared_dart)
        )
    if undeclared_kotlin:
        failures.append(
            "Kotlin registers channels this audit does not know (add them to CHANNELS): "
            + ", ".join(undeclared_kotlin)
        )
    unreached = sorted(expected - dart_names)
    unregistered = sorted(expected - kotlin_names)
    if unreached:
        failures.append("declared channels with no Dart end: " + ", ".join(unreached))
    if unregistered:
        failures.append("declared channels with no Kotlin end: " + ", ".join(unregistered))

    sites = dynamic_call_sites()
    unknown_sites = [site for site in sites if site not in DYNAMIC_SITES]
    if unknown_sites:
        failures.append(
            "non-literal dispatch sites outside DYNAMIC_SITES: " + ", ".join(unknown_sites)
        )
    stale_sites = sorted(set(DYNAMIC_SITES) - set(sites))
    if stale_sites:
        failures.append(
            "DYNAMIC_SITES declares sites that no longer exist: " + ", ".join(stale_sites)
        )

    print(
        f"channels: {len(CHANNELS)} method + {len(EVENT_CHANNELS)} event, "
        f"{total_handlers} handlers, {total_calls} distinct Dart calls"
    )
    print(
        f"events: {reported_emits} pushed Kotlin -> Dart, "
        f"{reported_consumers} Dart case arms; "
        f"{len(dart_names)} Dart / {len(kotlin_names)} Kotlin channel literals"
    )

    if failures:
        print("\nFAIL — channel contract:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(
        "\ncontract OK: every Dart call has a Kotlin handler, every Kotlin event a Dart "
        "consumer, every channel name a counterpart, and both ends agree on the prefix"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
