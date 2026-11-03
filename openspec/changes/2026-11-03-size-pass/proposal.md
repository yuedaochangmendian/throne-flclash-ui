# Size and runtime pass

## Why

The release APK carries 56 MB per ABI after earlier slimming rounds (VkLayer, debug AAR,
symbol strip, country_flags), but three known costs were still in the tree: R8 was not
shrinking app code at all (a blanket `-keep` on both app packages), a 1.4 MB emoji font
that no code path ever applied, and a `System.gc()` on the dashboard's release-memory tap.

## Changes

- `proguard-rules.pro`: the blanket `io.nekohasekai.sagernet.**` / `moe.matsuri.nb4a.**`
  keeps are replaced by the two surfaces that are actually reflective —
  `OutboundFactory`'s `outbound.types.**` and the ten preference classes `res/xml`
  inflates by tag name only. `android.enableR8.fullMode=true` turns on with them.
  `LineNumberTable` is kept so the seven-day crash records carry line numbers.
- `gradle.properties`: `android.enableJetifier=false` (no dependency ships
  `com.android.support` any more).
- `app/build.gradle.kts`: `useLegacyPackaging = false` — native libraries load from the
  APK instead of being extracted to `/data` at install time (no second copy of
  libflutter.so + the Go core on disk).
- Twemoji.Mozilla.ttf (1.4 MB) removed: the `emojiFont` hook the family serves is never
  wired (`BoxApp` passes no `emojiFont`, the font picker never lists the family), so the
  glyphs were dead weight. JetBrainsMono is subset to Latin/punctuation/box-drawing
  (267 KB to 71 KB). Launcher and banner artwork converted to WebP (-310 KB source).
- `dashboard.releaseMemory` no longer calls `System.gc()` on release builds (a full-heap
  pause on a UI tap); debug builds keep the call for the button's sake.
- `docs/toolchain-upgrade.md`: the dependency-pin cleanup (AGP ≥ 8.9 → unpin CameraX;
  Kotlin 2.2 → drop `-Xskip-metadata-version-check` and the version `force` block) is
  scheduled there as batches U1–U3 with `scan_aar_apis.py` staying as the permanent gate.

## Spec deltas

- `repository-governance`: R8 full mode plus the precise keep list is now the packaging
  contract; a new reflective surface must arrive with its own `-keep` rule.

## Verification

- Kotlin unit tests and `flutter analyze --fatal-infos` + `flutter test` in CI.
- The channel contract audit and the AAR API scan are unchanged and must stay green.
- `about_test.dart` pins the hero asset name (now `app_icon.webp`).
