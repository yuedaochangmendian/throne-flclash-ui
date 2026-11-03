# Size and runtime pass — tasks

- [x] Narrow `proguard-rules.pro` to the reflective surfaces (outbound.types + XML-inflated preferences) and enable R8 full mode
- [x] Disable Jetifier
- [x] ~~`useLegacyPackaging = false`~~ — shipped in 3.2.4, measured, and **reverted in 3.2.5**: STORED .so doubled the APK (120 MB/ABI) for a disk win the extract mostly paid back. Kept `useLegacyPackaging = true` with the measurement in the comment
- [x] Remove dead Twemoji asset; subset JetBrainsMono; convert launcher/banner artwork to WebP
- [x] Make `dashboard.releaseMemory` GC debug-only
- [x] Write `docs/toolchain-upgrade.md` (batches U1–U3) and point the roadmap debt table at it
- [x] CHANGELOG `#### 3.2.4` + `nb4a.properties` bump
- [x] CI green on the branch (Kotlin tests, flutter analyze --fatal-infos, flutter test, channel audit, AAR API scan) — run 41585528420
- [x] Release dispatch v3.2.4 (run 41586431828) — exposed the packaging regression; v3.2.5 carries the revert
- [ ] CI green + release dispatch for v3.2.5; verify arm64 APK is back under 60 MB
