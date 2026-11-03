# 工具链解钉（upgrade milestones）

> 状态 2026-11-03：规划中。本文件是 `docs/roadmap.md` 债项 #1/#2 的执行细则：把
> 「版本钉死」的脆弱平衡拆成可验证的升级步骤。每一节是一次独立可发版的批次，
> 节内步骤顺序执行，禁止跨节合并。

## 为什么必须做

宿主 Kotlin 2.0.21 通过 `-Xskip-metadata-version-check` 强行加载 Kotlin 2.2 元数据的
Flutter AAR，CameraX/rosemoe/kotlin-stdlib/coroutines 全部 `force` 钉在旧版本。这套平衡
今天能跑，但任何一次顺手的依赖升级都可能踩碎它（NoSuchMethodError 只在运行时暴露）。
`tools/diagnostics/scan_aar_apis.py` 是安全网，不是解决方案。

## U1 — AGP ≥ 8.9 + 解 CameraX 钉

前置：无（可直接做）。

1. `buildSrc/src/main/kotlin/Helpers.kt`：AGP 升到 8.9.x（Flutter 模块侧已是 AGP 9.1.0，宿主追平其下限）。
2. `app/build.gradle.kts`：删除 `resolutionStrategy` 里四个 `androidx.camera:*` 的 `force`，
   以及「CameraX: see the comment above」整段注释——`mobile_scanner` 要的 1.6.x 会自己解析。
3. 验证：`app:testOssDebugUnitTest` + `app:assembleOssDebug` 全绿；扫码页面真机走查
   （`docs/device-checklist.md` 的导入一节）；`scan_aar_apis.py` 结论不变。

## U2 — Kotlin 2.2 + 删元数据跳过

前置：U1 完成（AGP 8.9 对 Kotlin 插件版本的要求先满足）。

1. 宿主 Kotlin 2.0.21 → 2.2.x（与 Flutter 模块的 2.2.20 同代）。
2. `Helpers.kt`：删除 `-Xskip-metadata-version-check`。
3. `app/build.gradle.kts`：删除 `force` 里的 `org.jetbrains.kotlin:kotlin-stdlib*` 与
   `org.jetbrains.kotlinx:kotlinx-coroutines*` 六条，以及对应注释块。
4. 连带检查：KSP/Room 版本按 Kotlin 2.2 兼容矩阵对齐（KSP 版本号后缀随编译器版本变）。
5. 验证：同 U1，外加全量 `flutter test`（通道契约不受影响，但 `channel_audit.py` 必须重跑）。

## U3 — rosemoe editor 解钉（可选，跟 U1/U2 之后任意时刻）

1. `io.github.rosemoe:editor` 0.23.7 → 0.24.x（不再需要 `exclude kotlin-stdlib`）。
2. 验证：JSON 编辑器页面（schema 校验/补全/格式化）真机走查。

## 永久门禁（升级后也不许删）

- `tools/diagnostics/scan_aar_apis.py` 保留在 CI：它证明 Flutter AAR 只调用钉住的
  stdlib/coroutines 提供的 API。U2 完成后 force 消失，但 Flutter 侧仍会先行引用更新的
  Kotlin API——门禁继续挡住这类不对称。
- `tools/diagnostics/channel_audit.py`：与工具链无关，但两次升级都必须绿。

## 不在本文件内

- `targetSdk 36` 与上游 schema 适配：属 roadmap §4 的 v4.0.0（核心大版本跟随）。
- Flutter 工具链本身的升级（3.47.x → 未来）：独立批次，升级时必跑 N3 设备清单
  （roadmap §5 风险 2）。
