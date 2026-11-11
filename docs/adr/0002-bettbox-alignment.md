# ADR 0002 — 全量对齐 Bettbox（取代 ADR 0001）

- 日期：2026-11-11
- 状态：已接受
- 取代：`0001-ffi-boundary.md`（保守路线），其决策 1、4、5 与「明确不做」中的三条被本 ADR 推翻
- 影响范围：内核补丁、Dart 运行时、Kotlin 桥接、存储层、CI 门禁、发布链

## 背景

0001 记录了当时的四条链路：控制面走 dart:ffi 长驻 isolate、数据面走 MethodChannel
（Kotlin 持有 Room / `ProfileManager` / 配置生成 / 订阅解析 / 测速会话）、日志与状态走 Go
message port、前台服务走 MethodChannel。它据此定下「Kotlin 是数据面唯一所有者」「不推翻
typed ABI」「不做 Bettbox 式 JSON action」「不上 Riverpod」。

用户要求把整个项目（含内核架构）与 Bettbox 对齐。对比结论见
`flutter/lib/core/throne_kernel.dart`、`kernel_worker.dart`、`buildScript/core-patch/core/mobile/dartbridge.go`：
**传输层其实已经是 Bettbox 同款** —— `Dart_PostCObject_DL` 消息 port、长驻 isolate 独占
Instance handle、`NativeApi.initializeApiDLData`、`{"method","data"}` JSON 事件、状态快照聚合。
缺的是 Bettbox 的**协议层**：单一 `invokeAction` C 入口、`Action{id,method,data}` /
`ActionResult{id,data,code}`、`id → Completer` 关联、泛型 `invoke<T>`。

数据面要真正迁到 Go/Dart，还有一个 0001 未展开的硬前提：本项目约 120 个
`ThroneBoxBridge.kt` handler 建在 Room v20（7 个 `@Entity`）与 `DataStore` 上，这些 API 在
Go 进程里不可达。Bettbox 用 `lib/common/path.dart` 的文件/JSON 存储，因此能把数据面放在
Go/Dart。对齐架构就必须同时换掉存储层，这正是 0001 估算的 56k 行 Kotlin 重写的实质。

## 决策

1. **取代 0001**。保留原文作为历史，头部标注「已被 0002 取代」。
2. **统一协议层**：新增单一 `throne_invoke_action` C 导出，内核侧以
   `map[Method]handler` 分发 JSON `Action`，响应 `ActionResult` 回显 `id`；Dart 侧以
   `Map<String, Completer>` 关联，`Future<T> invoke<T>(...)` 为唯一入口。
3. **保留 424 个 typed 导出作为 handler 的实现**，不删生成物、不动 `tools/bindgen` 的
   三方等式。对齐的是「一个通用入口」，不是「删掉所有 typed 调用」。
4. **存储改为应用私有目录下的文件/JSON**（`profiles.json` / `routes.json` /
   `settings.json` / `groups.json`），原子写、版本化。冷启时从 Room v20 做一次性迁移，
   保留 id 映射；迁移成功后才切换读取源，Room 保留只读回退。
5. **数据面分批迁到 action handler**；Kotlin 最终只保留 Android 平台能力：VpnService 与
   TUN fd、通知、`state.stats`、`wifi.watch`、`apps.*`、SAF 备份、`data.path`、
   `ffi.mode`/`ffi.handle` 交接。
6. **进度事件改推送**：测速等长任务由 Go `notify` 经 message port 推状态，替掉 Dart 的
   250 ms 轮询；Action RPC 只返回最终结果。
7. **门禁不得拆**：`symbol_audit.py` 的三方符号等式、`channel_audit.py` 的双向通道对齐
   继续强制；新增 `action_contract.py` 校验 Go `Method` ↔ Dart `ActionMethod` ↔ 注册表。
   不通过放宽门禁来「修红」。
8. **状态管理与双 Flutter engine 留到二期**：一期不动 `BoxController extends ChangeNotifier` /
   `BoxScope` / `BoxAspect` / `BoxEventBus`（牵动约 35 个 widget 测试与 vendored `lib/ui`）；
   单 engine + 长驻 isolate 与 Bettbox 的双 engine 功能等价，二期再评估。

## 分期与验收线

| 期 | 内容 | 验收 |
| --- | --- | --- |
| 0 | 本 ADR、文档、`action_contract.py` 入 CI | 门禁链全绿，无运行时改动 |
| 1 | `throne_invoke_action` + 两份头文件 + Dart `invoke`/Completer | 本地重编 AAR 后符号可见；`symbol_audit.py` 三方相等；单元测试覆盖 id 关联、超时、错误码 |
| 2 | `document_store.dart` + Room→JSON 迁移 + `schema_audit.py` 调整 | 迁移测试用真实 v20 样例；老用户 profile/订阅/路由规则零丢失；Room 只读回退可用 |
| 3 | `routes.*` → `profiles.*` → `settings.*` → `config.build` → `speedTest.*` 迁到总线，Kotlin case 同步删除 | 每个域一个 PR；`channel_audit.py` 双向对齐；模拟器回归连接、测速、通知 |
| 4（二期） | Riverpod、双 Flutter engine、剩余平台面 | 另开计划 |

## 后果

**正面**：与 Bettbox 的协议、存储、事件模型一致；新增能力只需在 Go 注册表加一个 handler；
数据面不再受 Android Room 绑定；长任务进度由内核推送。

**负面**：这是迄今最大的一次改动。阶段 2 的迁移一旦漏字段会不可逆地丢用户数据；
`action_contract.py` 与既有 `symbol_audit.py` / `channel_audit.py` 形成三重契约，新增或删除
任一方法都需三处同步；每期都必须跑完整本地重编（`buildScript/local-env.sh` 已固化）。

## 明确不做（继承 0001 的护栏）

- 内嵌 mihomo 全树。
- 拆 CI 门禁来修红。
- 复制 Bettbox 自身的协议漂移：实测其 Go 侧 `resetConnectionsMethod` 与 Dart 侧
  `resetConnections` 字符串不一致、方法数 72 vs 74。本项目的三方枚举由脚本强校验。
- 一期改状态管理框架（见决策 8）。
