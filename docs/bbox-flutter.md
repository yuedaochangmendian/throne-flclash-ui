# The Flutter module

> Status 2026-11-14: rewritten after the migration to upstream FlClash v0.9.3. The old
> `io.flrone/box` + `io.flrone/events` contract, `BoxController` (`flutter/lib/box.dart`) and
> `ThroneBoxBridge.kt` are **deleted**; `flutter/flclash-manifest.json` (the v0.9.2 per-file
> vendoring record) is deleted too.

`flutter/` is a whole-tree fork of [FlClash v0.9.3](https://github.com/chen08209/FlClash)
(`be84736605527034689c95bf27828ff27d912c5e`, tag `v0.9.3`), not a file-by-file vendoring: `lib/`,
`test/`, `arb/`, `assets/`, `plugins/`, `tool/`, `shaders/`, `build.yaml`, `build_config.yaml` and
`pubspec.yaml` all come from upstream, and the Dart package is still `fl_clash`. Throne supplies the
runtime underneath; FlClash's own Riverpod/Drift application layer, pages and views are the app's
interface, and no Throne page tree is left.

## What was changed locally

Eight files differ from upstream, plus one new file — that is the whole adaptation:

| File | Change |
| --- | --- |
| `flutter/lib/bootstrap.dart` | On Android the profile list comes from Throne's repository (`coreController.listThroneProfiles()`) instead of Drift |
| `flutter/lib/common/http.dart` | `initCertificate` returns early on Android — Throne trusts the platform store and vendors no mihomo CA bundle |
| `flutter/lib/core/controller.dart` | `initGeo()` is skipped on Android (there is no bundled geodata to load) |
| `flutter/lib/core/core.dart` | Exports the new `throne_profiles.dart` |
| `flutter/lib/core/method.dart` | Adds the four `throneProfile*` wire names |
| `flutter/lib/core/throne_profiles.dart` | **New file** — the typed client for `throne.profile.list/save/update/delete`, mapping a Throne group to a FlClash `Profile` |
| `flutter/lib/providers/actions/profiles.dart` | Profile update goes to the native repository on Android and re-reads the native list |
| `flutter/lib/providers/database.dart` | `profilesStream` polls the native rows on Android and merges Drift's custom profiles in as an overlay |
| `flutter/pubspec.yaml` | `module:` config (`androidPackage: io.flrone.ui`), the `prism_ui` / `setup` / `rust_api` path deps, `hooks.user_defines` (`setup: build_assets: false`, `rust_api: build_assets: true`), and the mihomo CA-bundle asset removed |

`flutter/lib/ui/` is **not** a vendored Prism UI copy any more: it is FlClash's own thin adapter over
the `prism_ui` package (it re-exports `package:prism_ui/prism_ui.dart` and adds a handful of app
widgets). The upstream package itself lives at `flutter/plugins/prism_ui/lib` as a path dependency —
see `docs/prism-upstream.md`. That copy carries **no local patch**: it matches the pinned upstream
baseline byte-for-byte (145 files, 0 diverged), which is why the fork's old `banner.dart` change is
gone — it broke swipe-to-dismiss on action-less banners and six upstream banner tests.

## Channels

The device talks to Android through upstream's four platform plugins, registered in
`app/src/main/java/io/throne/bbox/flutter/BboxFlutterActivity.kt`; the names come from
`com.follow.clash` on both ends:

| Channel | Kind | Where |
| --- | --- | --- |
| `com.follow.clash/app` | MethodChannel | `flutter/lib/plugins/app.dart` ↔ `AppPlugin` |
| `com.follow.clash/battery` | MethodChannel | `flutter/lib/plugins/battery.dart` ↔ `BatteryPlugin` |
| `com.follow.clash/battery/optimization` | EventChannel | same pair — the exemption state |
| `com.follow.clash/service` | MethodChannel | `flutter/lib/plugins/service.dart` ↔ `ServicePlugin` (`init`, `shutdown`, `start`, `stop`, `getRunTime`, `syncState`, plus the `event` push) |
| `com.follow.clash/core` | MethodChannel | the same `Service` transport ↔ `ServicePlugin` → `ThroneCore` (`invokeMethod` carrying the JSON request) |
| `com.follow.clash/tile` | MethodChannel | `flutter/lib/plugins/tile.dart` ↔ `TilePlugin` |

The Core wire protocol these carry, and the `ThroneCore.kt` that answers it, is documented in
`docs/bbox-bridge.md`. There is no page-level channel and nothing that corresponds to the deleted
`ready` handshake: the UI calls `core.init` through `ServicePlugin`, and the bootstrap waits for
`CoreLib.start()` rather than for a first-frame plugin answer.

## Layout

```
flutter/                       FlClash v0.9.3, whole tree
  lib/                         the application (bootstrap, pages, views, providers, core, database)
  plugins/prism_ui/            the UI kit as an upstream package (path dependency)
  plugins/{setup,rust_api,...} upstream platform plugins; their build hooks live under hook/
  core/README.md               marks the repository root for the setup hook (no mihomo core here)
  build/host/outputs/repo/     the local Maven repo `flutter build aar` writes (gitignored)

app/src/main/java/
  com/follow/clash/            the four FlClash platform plugins (+ the models they need)
  io/throne/bbox/corehost/     ThroneCore.kt (the Core protocol) + ThroneServiceController.kt
  io/throne/bbox/bridge/       the six runtime helpers (see docs/bbox-bridge.md)
  io/throne/bbox/flutter/      BboxFlutterActivity.kt — plugin registration only
```

`BboxFlutterActivity` is the launcher (and the leanback launcher). It registers the four plugins in
`configureFlutterEngine`, then calls `CrashHandler.noteStarted()` to return the crash budget, and
holds no backend state of its own.

## Build

```bash
cd flutter
flutter pub get
flutter build aar --no-debug --no-profile     # the release AAR the host links
```

The host links `io.flrone.ui:flutter_release:1.0` (a plain `implementation`, not a
`debugImplementation`/`releaseImplementation` pair): the debug AAR ships the JIT engine and Dart as
interpreted kernel, which is ~150 MB of APK for hot reload this host never exercises. No `flutter`
command is needed to build the app afterwards — only after Dart changes.

### Prerequisites

* **Flutter 3.47.x** — CI pins `3.47.9` (`.github/actions/android-build/action.yml`).
* **Rust 1.99.0** plus the Android targets `aarch64-linux-android`,
  `armv7-linux-androideabi`, `x86_64-linux-android`
  (`flutter/plugins/rust_api/rust/rust-toolchain.toml`). The `rust_api` build hook runs
  cargo/bindgen, so `flutter build aar` also needs **libclang**; on Windows the NDK ships no libclang
  shared library, so a pip `libclang` wheel plus `LIBCLANG_PATH` is what works (the hook's own
  comment explains why). MinGW is the GNU toolchain the hook expects on Windows.
* **NDK 28.2.13676358** — the app's `ndkVersion` (`buildSrc/src/main/kotlin/Helpers.kt`). Without it
  the strip task cannot find `llvm-strip`, and every native library ships with its debug symbols.
* **compileSdk 37, targetSdk 35, minSdk 24** — `Helpers.kt`. The Flutter AAR declares
  `minCompileSdk=37`, so the host must compile against 37 while `targetSdk` stays 35.
* **`flutter/core/`** — `flutter/core/README.md` exists only so the `setup` hook's repository probe
  (`setup_hooks/CoreBuilder.repositoryRoot`) finds `<repo>/core/` before it honours
  `build_assets: false`. This fork vendors no mihomo core.
* **Build hooks** — `flutter/pubspec.yaml` sets `hooks.user_defines`: `setup.build_assets: false`
  (nothing to build; the proxy core is Throne's sing-box/Xray runtime) and
  `rust_api.build_assets: true` (the Rust bridge is built).

### Things that bite

* `flutter build aar` must run where no parent `settings.gradle.kts` shadows it; the module has its
  own generated `.android/` project, and `flutter create --template=module` has to run once if that
  directory is missing.
* Engine artifacts (`io.flutter:flutter_embedding_*`, `io.flutter:<abi>_<mode>`) come from
  `https://storage.flutter-io.cn/download.flutter.io` (or `storage.googleapis.com`). If the consuming
  app must resolve offline, copy them from the Gradle cache into the local repo's `io/flutter/`
  tree — `repositories.gradle.kts` already lists both mirrors as fallbacks.
* On Windows, if the Pub cache is on a different drive than the build tree, Kotlin incremental
  compilation fails with `this and base files have different roots`; set
  `kotlin.incremental=false` and `kotlin.incremental.useClasspathSnapshot=false`, and if the daemon
  then hangs, `kotlin.compiler.execution.strategy=in-process`.
* **Always `clean` after changing which AAR is linked.** Gradle's incremental packaging otherwise
  produces APKs padded with tens of MB of zero bytes between entries; `stat` disagreeing with the sum
  of ZIP entry sizes is the tell.

### Version constraints between the module and the host

| Where | Constraint |
| --- | --- |
| `flutter/.android/settings.gradle` | Flutter's Gradle plugin requires AGP >= 8.11.1 and KGP >= 2.2.20, so the module builds with AGP 9.1.0 / Kotlin 2.4.0 |
| `app` (`buildSrc/.../Helpers.kt`) | `compileSdk = 37` because the AAR declares `minCompileSdk=37`; `targetSdk` stays 35, `minSdk` 24 |
| `buildSrc/build.gradle.kts` + wrapper | The host uses AGP 8.12.3 / Kotlin 2.4.10 / Gradle 8.13 / KSP 2.3.13. AGP 9 is not an option: `buildSrc` and the wrapper are on 8.x, and androidx.core 1.19.1 (which arrives transitively) declares AGP 9 metadata — it is pinned to 1.18.0 in the root build file instead |
| `app/build.gradle.kts` | No dependency `force` remains. CI still scans the Flutter AAR for API references missing from the resolved kotlin-stdlib/coroutines |

## Packaging: dropping the Vulkan validation layer

The debug engine ships `libVkLayer_khronos_validation.so` — 237 MB uncompressed, ~65 MB inside the
APK, second only to `libflutter.so`. It is a graphics-debugging layer with no runtime role and the
release engine jar has zero `VkLayer` entries, so nothing can depend on it. `app/build.gradle.kts`
excludes it with `packaging { jniLibs { excludes += setOf("**/libVkLayer_khronos_validation.so") } }`.

## Why the native libraries were enormous: nothing was being stripped

A 272 MB debug APK whose `libflutter.so` alone accounted for 377 MB uncompressed was not Flutter's
fault: every native library shipped with full debug symbols because the strip task silently gave up
(`Unable to strip the following libraries, packaging them as they are: ... libthrone.so`). The app
has no C/C++ of its own, so nothing had ever set `ndkVersion` — and without it the strip task cannot
locate `llvm-strip`. Setting `ndkVersion` in `buildSrc/Helpers.kt` was the whole fix:

| | before | after |
| --- | --- | --- |
| `libflutter.so` | 377.53 MB (327.57 MB of it `.debug_*`) | 37.05 MB, zero symbol sections |
| APK (arm64-v8a) | 272.42 MB | 96.66 MB |

The *release* engine jar is 157 MB for the same reason — 139 MB of it is `.debug_*`, leaving 6 MB of
actual `.text`. Any Flutter app that forgets `ndkVersion` pays this, whichever build type it uses.
