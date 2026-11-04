# ADR 0001 — FFI 路径的边界（保守路线）

- 日期：2026-11-04
- 状态：已接受
- 影响范围：`flutter/lib/core/*`、`buildScript/core-patch/`、`app/.../BboxKernel.kt`、`ThroneBoxBridge.kt`

## 背景

`bettbox-vs-flrone.md` 对比了 Bettbox 与本项目：Bettbox 把配置生成、profile 存储、测速全部放在 Go/Dart，Kotlin 只剩 3,598 行；本项目反过来，Kotlin 侧约 56k 行持有 Room、`ProfileManager`、`CoreConfigs`、订阅解析和测速会话，Dart 约 77k 行负责 UI。

本项目另有一条 FFI 旁路：`core-patch`（423 个 `throne_*` 导出）→ `bindgen` → `throne_ffi.dart` → `KernelService`。目前四条链路并存：

| 链路 | 传输 | 所有者 |
| --- | --- | --- |
| 控制面（start/stop/reload/status/WARP） | dart:ffi（长驻 isolate） | Dart |
| 数据面（profile 存储、配置生成、订阅、测速会话） | MethodChannel | Kotlin |
| 日志与状态事件 | Go message port | Go |
| 前台服务 / VpnService | MethodChannel | Kotlin |

2026-11-04 的 `profile 0 is gone` 正是"数据面 id 语义被控制面猜错"的代价：Dart 从外观偏好里取 `selectedProxy`（恒为 0），Kotlin 只在参数为 null 时才回退 `DataStore.selectedProxy`。

## 决策

1. **Kotlin 是数据面唯一所有者**。profile 存储、`config.build` 生成、订阅解析、测速会话继续留在 Kotlin。
2. **FFI 只负责控制面**：创建/启动/停止/重载 Instance、状态快照、WARP 注册。`ffi.mode` 打开时通道的控制面处理让位。
3. **`config.build` 不传任何 id**。`BboxKernel.buildStartOptions()` 无参，由 `DataStore.selectedProxy` 权威解析；`resolveProfile()` 容忍陈旧 id、回退首个节点、无节点时给出可操作提示。`channel_audit.py::ffi_id_contract_failures()` 机器保证这条契约。
4. **不迁移后端**。把 profile 存储与配置生成搬到 Dart/Go 等于重写 56k 行 Kotlin，v3.x 不做。
5. **不推翻 typed ABI**。423 个导出与 gobind 面一一对应，由生成器维护；不做 Bettbox 式 19 个 JSON action 的重写。高频调用用 `throne_status_snapshot()` 收敛成一次跨边界。
6. **FFI 只在一个长驻 isolate 里打开**。UI isolate 不 `dlopen`、不创建句柄包装对象；Go 推送 `status` 事件，UI 订阅而非轮询。
7. **生成物与生成器同步由 CI 保证**：`symbol_audit.py` 对账 Go 导出 / 两份头文件 / Dart lookup，并检查 recover 防线与 finalizer。

## 后果

**正面**：改动面小、可跟随上游 Throne（纯增量补丁）、CI 门禁能覆盖，启动选档错误不可能再以同一种方式复发。

**负面 / 需持续维护**：数据面仍依赖 MethodChannel；四条链路的 wire shape 需要 `channel_audit.py` 与 `symbol_audit.py` 双重对账；句柄语义仍需显式 `release()` + `NativeFinalizer` 兜底。

若未来要把 `ffi.mode` 收口成单一路径，或把数据面迁到 Dart/Go，应另开 ADR 并评估重写成本，而不是在本 ADR 上追加例外。

## 明确不做

- 内嵌 mihomo 全树（991 文件上游同步成本）。
- 拆掉 CI 门禁来"修红"。
- Riverpod + `globalState` 双写；现有 `ChangeNotifier` 单一事实源更干净。
- 把 423 个 typed 导出改成 JSON action 总线。
