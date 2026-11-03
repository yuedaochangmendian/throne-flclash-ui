# Size and runtime pass — tasks

- [x] Narrow `proguard-rules.pro` to the reflective surfaces (outbound.types + XML-inflated preferences) and enable R8 full mode
- [x] Disable Jetifier
- [x] `useLegacyPackaging = false`
- [x] Remove dead Twemoji asset; subset JetBrainsMono; convert launcher/banner artwork to WebP
- [x] Make `dashboard.releaseMemory` GC debug-only
- [x] Write `docs/toolchain-upgrade.md` (batches U1–U3) and point the roadmap debt table at it
- [x] CHANGELOG `#### 3.2.4` + `nb4a.properties` bump
- [ ] CI green on the branch (Kotlin tests, flutter analyze --fatal-infos, flutter test, channel audit, AAR API scan)
- [ ] Release dispatch (`release.yml`, publish=true) and asset/SHA256SUMS check
