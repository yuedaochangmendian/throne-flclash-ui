# Flrone 下一阶段路线图

> 基线：`main` @ 2026-11-09，`VERSION_NAME=3.3.2`。稳定版 `v3.3.1`，最新预览 `v3.3.2-pre.24`。
> 本文只记录当前有效的工程规划；已完成的历史迁移见 `openspec/history/`。

## 1. 当前判断

- `main` 受保护，PR 必须通过 `Unit tests and debug build` 与 `Flutter module tests`。
- main CI 成功后只会在存在应用/构建输入变化时自动发布 preview。
- 安全扫描当前无开放告警。
- Flutter 自有代码覆盖率约 60.6%；生成 FFI 与 vendored UI 已从门槛中排除。
- 真机 arm64 / Android TV 回归仍是唯一无法由 CI 代替的发布门禁。

## 2. 发布线

| 版本 | 目标 | 状态 |
|---|---|---|
| `v3.3.2` | 稳定性、导入解析、扫码重构、维护性拆分 | 进行中 |
| `v3.4.0` | 路由/订阅体验的可用性完善与覆盖率提升 | 计划 |
| `v4.0.0` | compileSdk 37、依赖大版本、核心/schema 跟随 | 计划 |

## 3. v3.3.2：稳定性与维护性

### 交付项

- [x] GitHub 流程精简：缓存前移、文档快速路径、artifact 按需上传、每周治理。
- [ ] 订阅导入测试语料库：标准/URL-safe/wrapped Base64、JSON、分享链接、错误输入。
- [ ] Issue #14 验收：route/DNS 自动识别、多规则导入、非法 outbound、schema 错误。
- [ ] 轻量扫码：以 ZXingLite 宿主 Activity 替代 `mobile_scanner`，保持单码/多帧码/权限拒绝/返回路径。
- [ ] 解析器职责拆分：扫描/BOM/Base64 与各格式解析器分离。
- [ ] 桥接 wire 序列化从 `ThroneBoxBridge` 提取为可单测纯函数。
- [ ] 关键页面回归：协议表单、分组设置、自动选择器、测速面板、路由/规则编辑器。
- [ ] 覆盖率门槛升级：自有代码总门槛 58%，`box_api` 30%，页面目录 45%，并继续 ratchet。
- [ ] arm64 真机与 Android TV 设备清单通过并记录。
- [ ] 发布 `v3.3.2` stable。

### 验收

- PR CI、main CI、Release CI 全绿。
- 无开放 CodeQL / Dependabot / Secret Scanning 告警。
- 文档-only 提交不产生新 release。
- 所有导入失败都有可读原因，不出现空节点静默成功。
- 扫码四条真机路径均通过。

## 4. v3.4.0：体验与结构

### 解析与桥接

- 将 `ProfileImport` 拆分为：
  - `SubscriptionScanner`
  - `SingBoxImporter`
  - `ClashImporter`
  - `WireGuardImporter`
  - `OpenVpnImporter`
  - `ShareLinkImporter`
- 将 `ThroneBoxBridge` 的 wire serializers 与 feature dispatchers 分离。
- 对 `ConfigGenerator` 建立 golden config 测试后，再拆按 route / DNS / test / outbound 构建器。

### 生命周期

- 提取 kernel heartbeat / lost-core 状态机为可单测 reducer。
- 覆盖进程重建、强杀恢复、stop/dispose、adopt handle、超时恢复。
- `kernel_worker.dart` 建立独立覆盖率门槛。

### UI

- Issue #14 的剩余交互：列表字段改为可展开编辑，减少逗号分隔输入。
- 增加协议表单、分组设置、自动选择器的加载/保存/错误状态测试。
- 保持 vendored Prism 文件不参与项目重构，只允许记录明确的上游补丁。

## 5. v4.0.0：平台与依赖

升级顺序固定：

1. `compileSdk 37`，`targetSdk` 根据 Android 平台要求另行确认。
2. OkHttp `5.5.1`。
3. ZXingLite `3.5.0`，必须在轻量扫码已稳定之后。
4. rosemoe editor `0.24.x`。
5. ThroneCore pin 与 sing-box schema 同步升级。

每项都必须跑：

- 全量 Kotlin/Flutter 测试
- schema / AAR / channel / Python 审计
- 三 ABI 签名构建
- 覆盖升级
- arm64 真机与 TV 设备清单

### 风险

- OkHttp 5.5 ECH 相关 API 可能要求更高 compileSdk，不能只改依赖版本。
- ZXingLite 3.x 是 Kotlin 迁移版本，扫码 Activity 需要重新验证生命周期与返回结果。
- 上游 schema 变化可能同时影响 typed form、JSON 编辑器和 dashboard。

## 6. 发布与清理

- preview 不占 `releases/latest`，不包含 `throne-update.json`。
- stable 必须包含三个 ABI、`SHA256SUMS` 与更新清单。
- 保留最近 20 个 preview；更早的 preview 由维护者确认后清理。
- 文档-only 合并不得生成新版本，也不得新增 artifact。

## 7. 已知外部待办

- Issue #13：等待可复现的 Base64 订阅样本；测试语料库先覆盖支持范围。
- Issue #14：主体已实现，完成真实样例验收后关闭。
- Issue #17：arm64 / TV 设备矩阵。
- PR #9：OkHttp 5.5.1，等待 compileSdk 37 升级。
- PR #6：ZXingLite 3.5.0，等待轻量扫码稳定后重跑。
