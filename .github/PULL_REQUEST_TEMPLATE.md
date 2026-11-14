# Pull Request

## 变更说明

<!-- 简述改了什么、为什么改；一个 PR 尽量只包含一个自洽改动。 -->

关联 Issue：<!-- 如 #123；无则写「无」 -->

关联 openspec change：<!-- 如 openspec/changes/2026-11-05-xxx/；纯文档或不涉及规范变更写「不涉及」 -->

## 变更类型

- [ ] Bug 修复
- [ ] 功能 / 行为变更
- [ ] 文档 / 治理
- [ ] 构建 / CI / 工具链
- [ ] 其他：

## 验证清单

本地或 CI 已运行以下检查（对应 `.github/workflows/ci.yml`）：

- [ ] `flutter pub get` && `flutter analyze --fatal-infos`（在 `flutter/` 目录，零告警）
- [ ] `flutter test --coverage`（CI 另以 `coverage_gate.py` 校验覆盖率下限）
- [ ] Kotlin 单测与 debug 构建：`./gradlew app:testOssDebugUnitTest app:assembleOssDebug`
- [ ] Bridge contract audits（`channel_audit.py` / `symbol_audit.py` / `settings_audit.py` / `ffi_regression_test.py` / `generated_models_check.py` / `schema_audit.py`）全部通过
- [ ] Prism UI 漂移：`python3 tools/diagnostics/prism_drift.py check --local flutter/plugins/prism_ui/lib`
- [ ] `python3 tools/diagnostics/py_syntax_check.py tools/diagnostics/*.py tools/bindgen/*.py buildScript/*.py`
- [ ] 改动涉及通道名或 Core 协议方法时，已同步 Dart（`CoreMethod` / `packageName`）与 Kotlin（`ThroneCore.dispatch` / `Components.PACKAGE_NAME`）两端，并核对 `docs/bbox-bridge.md`
- [ ] 改动涉及规范时，已同步 `openspec/specs/` 或提交 `openspec/changes/` 变更提案

真机 / 设备清单（涉及 UI、VPN、覆盖升级、备份、Android TV 等运行时行为时，按 `docs/device-checklist.md` 走查）：

- [ ] arm64 真机：新装首启 / 覆盖升级 / 连接与切换节点
- [ ] Android TV（或模拟器）：D-pad 导航与焦点
- [ ] 不涉及运行时行为，或已在下方注明未覆盖的环境与原因

## 其他说明

<!-- 兼容性影响（尤其是签名、包结构、订阅 / 备份格式）、截图、后续待办等。 -->
