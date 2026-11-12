# 贡献指南（Contributing）

感谢你考虑为 Flrone 贡献。本文件说明开发环境、本地验证、提交流程与需要同步的契约。命令与路径均对应仓库内真实配置：`.github/workflows/ci.yml`、`.github/actions/android-build/action.yml`、`tools/diagnostics/`、`openspec/`。

## 1. 开发环境

| 组件 | 版本 / 说明 | 依据 |
|---|---|---|
| Flutter | 3.47.x；发布构建固定 `3.47.9` | `.github/actions/android-build/action.yml` 的 `flutter-version: '3.47.9'`；`ci.yml` 的 Flutter 测试 job 使用 `stable` channel |
| JDK | **17**（Temurin） | 同上 `java-version: '17'`；`buildSrc/src/main/kotlin/Helpers.kt` 中的 `JavaVersion.VERSION_17` |
| Android SDK | 本机安装，需含 build-tools（`apksigner`、`aapt2`） | `buildScript/release_assets.py` |
| NDK | `28.2.13676358` | `ci.yml` 的 clang 路径与 `android-build/action.yml` 的 `ndk;28.2.13676358` |
| 构建入口 | `./gradlew` | `android-build/action.yml` 的 Gradle build 步骤 |

Flutter module 位于 `flutter/`，Gradle 主工程在仓库根目录；发布构建会先生成 Flutter AAR 再执行 Gradle 任务。应用支持 Android 7.0（API 24）及以上，含 Android TV。

## 2. 本地验证命令

CI（`ci.yml`）在功能分支的 PR 与 `main` 的 push 上运行以下检查，提交前建议在本地跑一遍（Flutter 命令在 `flutter/` 目录，其余在仓库根目录）：

```bash
# Flutter 静态分析与测试
cd flutter && flutter pub get
flutter analyze --fatal-infos
flutter test --coverage
# CI 在 flutter/ 目录另以覆盖率下限脚本收口（与 ci.yml 同一数值）
python3 ../tools/diagnostics/coverage_gate.py coverage/lcov.info --min 40
cd ..

# 契约 / 一致性诊断脚本（回到仓库根目录）
python3 tools/diagnostics/channel_audit.py
python3 tools/diagnostics/symbol_audit.py
python3 tools/diagnostics/settings_audit.py --summary
python3 tools/diagnostics/ffi_regression_test.py
python3 tools/diagnostics/generated_models_check.py
python3 tools/diagnostics/py_syntax_check.py tools/diagnostics/*.py tools/bindgen/*.py buildScript/*.py

# Flutter AAR 的 API 扫描（先构建 AAR，路径写法与 ci.yml 一致）
AAR=$(find flutter/build/host/outputs/repo -name "*.aar" | head -1)
python3 tools/diagnostics/scan_aar_apis.py "$AAR"
python3 tools/diagnostics/check_preamble.py

# Kotlin 单元测试与 debug 构建
./gradlew --stacktrace app:testOssDebugUnitTest app:assembleOssDebug
```

CI 还会用 NDK 的 clang 检查 cgo preamble，并要求 `flutter analyze --fatal-infos` 零告警。`generated_models_check.py` 静态核对 `@freezed` 模型与随仓库分发的生成文件是否一致（见脚本头部与 `flutter/lib/ui/generated/README.md`）；完整步骤以 `.github/workflows/ci.yml` 为准。

## 3. 分支与提交约定

> GitHub 分支、发版、tag、release 与更新器的完整规则见 [docs/github-workflow.md](docs/github-workflow.md)；本节是日常提交细则。

- 从最新 `main` 创建**功能分支**，在分支上提交并推送；CI 通过 Pull Request 验证功能分支，`main` 另有 push CI。
- 通过 **Pull Request** 合并，合并前需 CI 全绿；**不要直接向 `main` 推送提交**。`main` 的推进与发版由维护者按 `docs/release-runbook.md` 执行。
- 提交信息写清改动目的；涉及行为规范变更时按第 4 节同步 `openspec/`。
- PR 请填写 `.github/PULL_REQUEST_TEMPLATE.md` 的验证清单；涉及运行时行为时对照 `docs/device-checklist.md`。

## 4. openspec 变更流程

仓库用 openspec 管理规范：

- `openspec/specs/` 存放现行规范（如 `proxy-connection`、`backup-restore`、`repository-governance` 等）；
- 变更走 `openspec/changes/<change-id>/`（`proposal.md`、`tasks.md` 与 spec delta），完成后归档到 `openspec/changes/archive/`；配置见 `openspec/config.yaml`；
- 改变行为时先提变更提案并实现，随后同步 `openspec/specs/` 中对应规范，避免规范与代码漂移；`README.md` 的 Development 段同样指明这一流程；
- `.roo/commands/opsx-*.md` 提供 propose / apply / sync / archive 等阶段的命令描述，可供参考。

## 5. 通道契约必须两端同步

Flutter（Dart）与宿主（Kotlin）之间的 channel 方法／事件由 `tools/diagnostics/channel_audit.py` 约束：它扫描 Dart 侧的 `box.call('…')` / `events.add({'type': …})` 与 Kotlin 侧的 `when(call.method)` / `emit("…")`，双端差集必须为空，且该脚本已在 CI 中运行。

因此**新增、改名或删除任何桥接方法或事件时，必须同时修改两端**；只改一端会导致 `channel_audit.py` 失败。`Capabilities.kt` 是 B-box 独有能力开关的唯一来源，`docs/bbox-bridge.md` 记录桥接层的每个方法与事件，改动时应一并核对。

## 6. 代码与文档一致性

- 文档中的版本号、`THRONE_CORE_REF`、命令与字段以仓库内实际配置为准；不确定时采用保守表述，不要凭记忆填写。
- 本仓库为下游发行版，核心（sing-box / Xray）按 `nb4a.properties` 的 `THRONE_CORE_REF` 固定并由 CI 构建；请勿在本仓库内改动上游核心代码。

行为准则见 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)，安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。
