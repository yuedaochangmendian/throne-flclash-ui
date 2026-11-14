# 贡献指南（Contributing）

感谢你考虑为 Flrone 贡献。本文件说明开发环境、本地验证、提交流程与需要同步的契约。命令与路径均对应仓库内真实配置：`.github/workflows/ci.yml`、`.github/actions/android-build/action.yml`、`tools/diagnostics/`、`openspec/`。

## 1. 开发环境

| 组件 | 版本 / 说明 | 依据 |
|---|---|---|
| Flutter | 3.47.x；CI 固定 `3.47.9` | `.github/actions/android-build/action.yml` 的 `flutter-version: '3.47.9'` |
| Rust | `1.99.0` + Android targets（`aarch64-linux-android`、`armv7-linux-androideabi`、`x86_64-linux-android`） | `flutter/plugins/rust_api/rust/rust-toolchain.toml` |
| libclang | `flutter build aar` 的 bindgen 需要；Windows 上 NDK 不带 libclang，用 pip 的 libclang wheel + `LIBCLANG_PATH`，GNU 工具链走 MinGW | `flutter/plugins/rust_api/hook/build.dart` 的注释 |
| JDK | **17**（Temurin） | `.github/actions/android-build/action.yml` 的 `java-version: '17'`；`buildSrc/src/main/kotlin/Helpers.kt` 的 `JavaVersion.VERSION_17` |
| Android SDK | compileSdk **37**、targetSdk 35、minSdk 24；需含 build-tools（`apksigner`、`aapt2`） | `buildSrc/src/main/kotlin/Helpers.kt`；`buildScript/release_assets.py` |
| NDK | `28.2.13676358` | `Helpers.kt` 的 `ndkVersion`；`ci.yml` 的 clang 路径与 `android-build/action.yml` 的 `ndk;28.2.13676358` |
| 构建入口 | `./gradlew` | `android-build/action.yml` 的 Gradle build 步骤 |

Flutter module 位于 `flutter/`（FlClash v0.9.3 整树 fork，包名仍是 `fl_clash`），Gradle 主工程在仓库根目录；发布构建会先生成 Flutter AAR 再执行 Gradle 任务。应用支持 Android 7.0（API 24）及以上，含 Android TV。

两个 build hook 的开关在 `flutter/pubspec.yaml` 的 `hooks.user_defines`：`setup.build_assets: false`、`rust_api.build_assets: true`。`flutter/core/` 只有一份 `README.md`，作用是让 `setup` hook 的仓库根探测通过——本仓库不 vendor mihomo 核心，代理内核是 Throne 的 sing-box/Xray。

## 2. 本地验证命令

CI（`ci.yml`）在每次 push 与 PR 上运行下面的检查，提交前建议在本地跑一遍（Flutter 命令在 `flutter/` 目录，其余在仓库根目录）：

```bash
# Flutter 静态分析与测试（AAR 需要先能构建，见第 1 节的 Rust/libclang/NDK）
cd flutter && flutter pub get
flutter analyze --fatal-infos
flutter test --coverage
python3 ../tools/diagnostics/coverage_gate.py coverage/lcov.info --min 40
cd ..

# 仍在 CI 中的诊断脚本（回到仓库根目录）
python3 tools/diagnostics/prism_drift.py check --local flutter/plugins/prism_ui/lib
python3 tools/diagnostics/py_syntax_check.py tools/diagnostics/*.py tools/bindgen/*.py buildScript/*.py

# cgo preamble 检查（需要 NDK 的 clang）
python3 tools/diagnostics/check_preamble.py

# Kotlin 单元测试与 debug 构建
./gradlew --stacktrace app:testOssDebugUnitTest app:assembleOssDebug
```

`flutter analyze --fatal-infos` 必须零告警——CI 用同一参数收口，没有「info 级不阻塞」的余地。

**不要再照抄下面这些**：`tools/diagnostics/` 里仍有五个脚本引用了迁移时删掉的文件（`flutter/lib/box.dart`、`Capabilities.kt`、`flutter/lib/data/db.dart`、`flutter/lib/ui/models.dart`），本地跑会直接 `FileNotFoundError` / `FAIL — missing file` / `setUpClass ERROR` 退出：

`channel_audit.py`、`symbol_audit.py`、`settings_audit.py`、`ffi_regression_test.py`、`generated_models_check.py`、`schema_audit.py`。

它们描述的是已经删除的页面级桥（`io.flrone/box` 契约、`Capabilities.kt` 能力表、`flutter/lib/data/` 直读层）。要恢复为门禁，得先按新的 Core 协议重写；在此之前**以 `ci.yml` 实际运行的那几步为准**，不要把它们当成「运行即绿」的本地检查。

> `prism_drift.py check` 的默认 `--local` 仍指向 `flutter/lib/ui`（迁移后那里只剩 FlClash 的适配层），所以本机调用必须显式带 `--local flutter/plugins/prism_ui/lib`，否则报告会是 `removed: 144`。

## 3. 分支与提交约定

- 从最新 `main` 创建**功能分支**，在分支上提交并推送；CI 对每次 push 与 PR 都会运行。
- 通过 **Pull Request** 合并，合并前需 CI 全绿；**不要直接向 `main` 推送提交**。`main` 的推进与发版由维护者按 `docs/release-runbook.md` 执行。
- 提交信息写清改动目的；涉及行为规范变更时按第 4 节同步 `openspec/`。
- PR 请填写 `.github/PULL_REQUEST_TEMPLATE.md` 的验证清单；涉及运行时行为时对照 `docs/device-checklist.md`。

## 4. openspec 变更流程

仓库用 openspec 管理规范：

- `openspec/specs/` 存放现行规范（如 `proxy-connection`、`backup-restore`、`repository-governance` 等）；
- 变更走 `openspec/changes/<change-id>/`（`proposal.md`、`tasks.md` 与 spec delta），完成后归档到 `openspec/changes/archive/`；配置见 `openspec/config.yaml`；
- 改变行为时先提变更提案并实现，随后同步 `openspec/specs/` 中对应规范，避免规范与代码漂移；`README.md` 的 Development 段同样指明这一流程；
- `.roo/commands/opsx-*.md` 提供 propose / apply / sync / archive 等阶段的命令描述，可供参考。

## 5. 通道与 Core 协议必须两端同步

界面与宿主的契约现在只有两层，都需要两端同时改：

1. **平台插件通道** —— 通道名与上游 FlClash 一致：`com.follow.clash/{app,battery,battery/optimization,service,core,tile}`。名字由两端各自的同一个 `com.follow.clash` 字面量拼出（Dart 侧 `flutter/lib/common/constant.dart` 的 `packageName`，Kotlin 侧 `com/follow/clash/common/Components.kt` 的 `PACKAGE_NAME`），改名必须两处一起动；四个插件在 `BboxFlutterActivity.configureFlutterEngine` 注册。`flutter analyze` 不校验方法名字符串，改完请全文 grep 两端核对。
2. **Core wire protocol** —— `com.follow.clash/core` 上的 `invokeMethod` 承载 JSON `{id, method, arguments}`。方法名在 Dart 侧是 `CoreMethod` 枚举（`flutter/lib/core/method.dart`），Kotlin 侧是 `ThroneCore.dispatch` 的 `when (method)` 分支，事件类型在 `flutter/lib/core/event.dart` 消费。新增或改名必须两处同时改。

`docs/bbox-bridge.md` 记录了协议的方法表、六个运行时助手和通道清单；`docs/bbox-flutter.md` 记录本地改动与构建前置。CI 的 `channel_audit.py` 已重写为核对上述五条 `com.follow.clash/*` 通道及 `packageName` 常量，`symbol_audit.py`、`ffi_regression_test.py` 等诊断也已按新架构重写（见 `.github/workflows/ci.yml` 的 Bridge contract audits 步骤）。旧的 `io.flrone/box` 通道契约与 `Capabilities.kt` 已随页面级桥删除，不再受审计。

## 6. 代码与文档一致性

- 文档中的版本号、`THRONE_CORE_REF`、命令与字段以仓库内实际配置为准；不确定时采用保守表述，不要凭记忆填写。
- 本仓库为下游发行版，核心（sing-box / Xray）按 `nb4a.properties` 的 `THRONE_CORE_REF` 固定并由 CI 构建；请勿在本仓库内改动上游核心代码。

行为准则见 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)，安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。
