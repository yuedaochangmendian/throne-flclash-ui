# 工具链解钉（upgrade milestones）

> 状态 2026-11-10：U1/U2/U3 已实施，compileSdk 37 与 OkHttp 5.5.1 随 v4.0.0 升级；真机回归仍按设备清单执行。本文件记录
> `docs/roadmap.md` 债项 #1/#2 的解钉方案与仍需保留的门禁。

## 为什么必须做

宿主曾以 Kotlin 2.0.21 通过 `-Xskip-metadata-version-check` 强行加载更新元数据的
Flutter AAR，并把 CameraX/kotlin-stdlib/coroutines 全部 `force` 钉在旧版本。任何一次
顺手的依赖升级都可能踩碎这套平衡（NoSuchMethodError 只在运行时暴露）。

U1/U2 已把工具链整体抬到 **Kotlin 2.4.10 + AGP 8.12.3 + Gradle 8.13 + KSP 2.3.13**，
删除了 `-Xskip-metadata-version-check` 与全套 `force`。关键发现：`mobile_scanner 7.4.2`
（B-box Flutter 模块引入的二维码插件）是用 **Kotlin 2.4.0** 编译发布的——它的 AAR 元数据
版本是 2.4.0、POM 声明 `kotlin-stdlib 2.4.0`。原注释里记的「2.2.10」是过时信息。宿主必须
升到 Kotlin 2.4.x（能读 2.4.0 元数据）才能在不跳过元数据检查的前提下链接它；这也是本次
一次性把 Kotlin 抬到 2.4.10 而非 2.2.20 的原因。

rosemoe 的独立升级仍属 U3。`tools/diagnostics/scan_aar_apis.py` 继续作为安全网。

## U1 — AGP ≥ 8.12 + 解 CameraX 钉 ✅

前置：与 U2 合并实施。KSP 2.3.13 硬性要求 AGP ≥ 8.12.0，而 Kotlin 2.4 要求 AGP ≥ 8.5.2；
两者取严，AGP 抬到 8.12.3。

1. `buildSrc/build.gradle.kts`：AGP 8.8.1 → 8.12.3，wrapper 同步升到 Gradle 8.13
   （AGP 8.12 要求 Gradle ≥ 8.13）。
2. `app/build.gradle.kts`：删除 `resolutionStrategy` 里四个 `androidx.camera:*` 的 `force`，
   以及「CameraX: see the comment above」整段注释——`mobile_scanner` 要的 1.6.x 靠 AGP 8.12
   自然解析（CameraX 1.6.1 只要求 AGP ≥ 8.9.1）。
3. 验证：`app:testOssDebugUnitTest` + `app:assembleOssDebug` 全绿；扫码页面真机走查
   （`docs/device-checklist.md` 的导入一节）；`scan_aar_apis.py` 结论不变。

## U2 — Kotlin 2.4 + 删元数据跳过与全套 force ✅

前置：U1 完成。

1. 宿主 Kotlin 2.0.21 → 2.4.10（KGP + Compose 编译器插件同步）。
2. KSP `2.0.21-1.0.27` → `2.3.13`（KSP 2.4.0 尚未发布到 Maven Central，且要求 AGP ≥ 8.12；
   2.3.13 已支持 Kotlin 2.4）。Room 保持 2.6.1。
3. `Helpers.kt`：删除 `-Xskip-metadata-version-check`；`jvmTarget` 写法迁移到 `compilerOptions` DSL
   （Kotlin 2.2+ 已把 `KotlinJvmOptions` 判为错误）。
4. `app/build.gradle.kts`：删除 `force` 里的 `org.jetbrains.kotlin:kotlin-stdlib*` 与
   `org.jetbrains.kotlinx:kotlinx-coroutines*` 六条及注释块；`kotlinx-coroutines-android`
   声明 1.6.4 → 1.11.0（与 mobile_scanner 声明、scan 基线对齐）。Kotlin 2.4.10 直接读
   mobile_scanner 的 2.4.0 元数据，无需 force 也无需 skip-metadata。
5. `scan_aar_apis.py`：参考基线 stdlib 2.2.20 → 2.4.10。
6. 验证：同 U1，外加全量 `flutter test`（通道契约不受影响，但 `channel_audit.py` 必须重跑）。

## U3 — rosemoe editor 解钉 ✅

1. `io.github.rosemoe:editor` 0.23.7 → 0.24.7，并删除 `exclude kotlin-stdlib`。
2. 验证：JSON 编辑器单测、Flutter 全量测试与 Android debug 构建通过；真机走查仍按设备清单执行。

## 永久门禁（升级后也不许删）

- `tools/diagnostics/scan_aar_apis.py` 保留在 CI：它证明 Flutter AAR 只调用宿主解析的
  stdlib/coroutines 版本提供的 API。force 消失后，Flutter 侧仍会先行引用更新的 Kotlin
  API——门禁继续挡住这类不对称；参考基线已随宿主更新为 stdlib 2.4.10 / coroutines 1.11.0。
- `tools/diagnostics/channel_audit.py`：与工具链无关，但每次升级都必须绿。

## 不在本文件内

- `app/libs/ThroneCore.aar` 的生成：由 CI `.github/actions/throne-core` 用 gomobile/gobind
  从 `throneproj/Throne`（`THRONE_CORE_REF`）编译产出，与工具链版本无关；本地全量 app 构建
  需先具备该 AAR，否则 `io.throneproj.mobile.*` 符号缺失。
- `targetSdk 36` 与上游 schema 适配：属 roadmap §4 的 v4.0.0（核心大版本跟随）。
- Flutter 工具链本身的升级（3.47.x → 未来）：独立批次，升级时必跑 N3 设备清单
  （roadmap §5 风险 2）。
