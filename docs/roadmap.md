# throne-flclash-ui 未来发展规划（AI Agent 执行文档）

> 版本：v1.0（2026-11-03 定稿）。基线：`main` @ `364cda9`（**v3.0.11**，VERSION_CODE 124），CI 全绿，`releases/latest` = v3.0.11。【注：以上为 2026-11-03 的**历史基线快照**，仅记录当时的仓库状态，勿作为当前版本依据；当前版本请以 `nb4a.properties` 的 `VERSION_NAME` 与 `CHANGELOG.md` 首段为准（截至本次文档整理时为 3.2.25）。】
> 用途：全功能迁移（bbox-full-parity）已于 2026-11-01 完成、旧 UI 退役并归档（`openspec/history/bbox-full-parity.md`），本文档是**后迁移时代的接续规划**，任何 agent 接手时以本文为任务来源。执行前先 `git fetch`（代理断连用 `git -c http.proxy= fetch`）确认基线之后的提交；若前提已变，先做增量审计再动手。
> 姊妹文档：仓库内 `docs/bbox-full-parity-plan.md`（已完成的迁移规划，其 §2 硬性规则全部沿用）。
> 执行状态（2026-11-03）：W1/v3.0.12 ✅、v3.0.13 ✅、批次 M 的 M1/M2/M5 ✅、批次 N 的 N1–N4 ✅、工具链 U1/U2 ✅；本文档随仓库分发，批次 O 及里程碑表以 §4 为准。

---

## 1. 现状盘点（基线事实，执行时勿再重复审计）

### 1.1 已完成、勿重做

- **迁移收官**：批次 0.5→A→B→C→D×2→E1→E2→F→G→H→I→J→K→L0/L1/L2 全部落地（46 commits）；旧 Fragment 树与 29 个协议 Activity 已删；Flutter 是唯一界面（3.0.0 起）；openspec 提案已归档
- **v3.0.x 打磨线**（3.0.1–3.0.11）：协议 typed 表单 + 测速面板细化、国旗徽章（矢量 SVG）、logcat 通道（tail-reader、清屏不阻塞主线程）、日志导出反馈、设置行值展示、probe 会话生命周期修复（v3.0.11）
- **质量现状**：Flutter 221 测试全绿 + Kotlin 单测（备份/解析器/设置契约/发布说明）+ `flutter analyze --fatal-infos` 零告警（CI 确实带该参数，见 `.github/workflows/ci.yml`）；`tools/diagnostics/` 已有 `settings_audit.py`、`scan_aar_apis.py`、i18n 三件套
- **自更新链路已加固**：`UpdateChecker` 读 `throne-update.json`（name/size/sha256），`UpdateVerifier` 落盘后校验 sha256——不必重做，只需保持测试
- **能力开关现状**（`Capabilities.kt`）：true = routes/autoSelector/warp/connections/logs/groups/memory/proxyGroups/clashModes/perApp/backup/lanProxy；**false = 12 项 B-box 独有能力**（terminal/capture/remote/reports/stun/quality/endpoints/taildrop/perAppManaged/rootQuery/dnsObject）

### 1.2 已知的债与坑（含 2026-11-03 实录）

| # | 内容 | 证据 | 归属 |
|---|---|---|---|
| 1 | ~~依赖链 force 降级与元数据跳过~~：U2 已升 Kotlin 2.4.10 并删除全套 force 和 `-Xskip-metadata-version-check`；`scan_aar_apis.py` 以新版宿主依赖为基线继续守门 | `app/build.gradle.kts` | ✅ U1/U2；rosemoe 解钉仍属 U3 |
| 2 | ~~CameraX 1.5.3 钉死~~：U1 已升 AGP 8.12.3 / Gradle 8.13，CameraX 1.6.1 自然解析；compileSdk 36 仍是 Flutter AAR 的独立要求 | `app/build.gradle.kts` | ✅ U1 |
| 3 | ~~analyze 存量 167 条 info~~：M3 已清零，CI 现以 `flutter analyze --fatal-infos` 收口且零告警 | `flutter analyze --fatal-infos` | ✅ 已解决 |
| 4 | ~~README 仍是上游 Throne 原文~~：已重写为 Flrone；命名统一在 `opt/flrone-naming` 完成——Flutter 包名、AAR 坐标、通道、rootProject、APK/artifact 前缀全部改为 Flrone；**applicationId `com.throneflclash` 与仓库名按决策保留**，以免现有用户无法覆盖安装 | `README.md` | ✅ 已解决 |
| 5 | docs 失实风险：`bbox-bridge.md`/`bbox-flutter.md` 在 0.5 修过一轮，3.0.x 又漂移了十余轮 | docs/ | M |
| 6 | 核心侧日志噪音：TUN lazy 握手下本地 app 提前 RST → `connection: report handshake success: go: connection reset by peer`（ERROR 级，reF1nd/sing-tun `stack_go_conn.go:51` errGoReset；核心 pin 上游不可修） | 本会话已定性 | N |
| 7 | 并行会话互踩：2026-11-03 两个 agent 会话同时改本仓库，一方 commit 落进另一方新建的分支 | 该教训记录于本表（§1.2 第 7 项）；AGENTS.md 未随仓库分发 | 治理 |
| 8 | 验证盲区：所有发布只经 CI（单测/构建/lint），**真机从未系统走查**（TV 焦点、VPN 升级安装、备份恢复跨版本） | 无真机测试记录 | N |

---

## 2. 战略定位（先选路线，再排任务）

本仓库本质是 **throneproj/Throne 上游 + 全面重写的 Flutter UI** 的下游发行版。三条路线：

- **A. 跟随上游，UI 领先**（推荐，本规划默认）：核心钉 `THRONE_CORE_REF` 定期跟进，开发力量全部投在 UI/桥层/体验；上游的协议与配置面自动继承
- **B. 特化独立产品**：走向 Flrone 品牌（README/docs 命名统一、独立文档站），功能上补 B-box 独有能力形成差异
- **C. 反哺上游**：把 Flutter UI 贡献回 throneproj（工作量大、不可控，不作为目标；仅顺手提小修）

**执行立场：A 为主、B 为辅**——W2 先把身份与文档理顺（半个 B），W4 按 B-box 能力逐项评估补齐（B 的差异化），核心层永远保持「pin + 跟随」（A）。

---

## 3. 工作流（W1–W7）

> 每批节奏沿用旧规划 §2：一次一个最小自洽批次 → 完整实现 → push → CI 全绿 → 里程碑前双 agent 并行 code review（浅扫 + 专项）→ 修 ≥80 分项 → spec 同步（openspec MUST 条款）→ 发版。**批次内禁止混入其他批任务。**

### W1 · ~~v3.0.12 在途收尾~~ ✅ 已完成（2026-11-03，commit `41636a9`）

- BboxLogcat.kt 重写为可注入进程的 LogcatReader（Mutex 保护、带超时的 clear，JVM 可单测，新增 BboxLogcatTest 477 行）；logs.dart 导出 tri-state + 防重入 + 空列表禁用，logs_test 补三态/防重入用例；探针会话重构为 BboxProbeSession（close 取消在飞请求 + 释放资源），`respond` 补 CancellationException 语义（scope 已关/会话已关返回 "cancelled"）；routed_ip_probe 补 `_closed` 语义（close 等待延迟 open，防残留 session）；顺带 shape_badge 焦点环改为前景绘制（不透明子组件不再遮盖）
- Flutter 226 测试全绿（+5）；CI run 41485297569 成功，v3.0.12 已发（prerelease=false，latest 指向正确）
- 遗留观察（已闭合）：`probeGet` 从 computeIfAbsent 自愈改为「缺 session = CancellationException」——约定由传输层本身强制（`routed_ip_probe.get` 首次调用自开 session，native 侧对缺 session 一律 fail-closed 返回 cancelled），新调用方沿用 `RoutedIpProbe` 即无序额外校验

### W2 · 批次 M：技术债与身份理顺（v3.1.0）

- **M1 依赖链收窄**：跑 `scan_aar_apis.py` 复核 Flutter AAR（3.47.9 工具链产物）对 coroutines/stdlib 的实际 API 引用；能解除 force/排除就解除，不能解除则在 docs 里写明风险边界与升级路径；`-Xskip-metadata-version-check` 目标删除
- **M2 camera 与 compileSdk**：评估 camera 1.6.1 降级到兼容 compileSdk 35 的版本（扫码是唯一用途），或接受 36 并记录原因
- ~~**M3 analyze 清零**：一次性修掉 167 条 info（curly_braces/unnecessary_import 全部是机械修复），此后 CI 加 `--fatal-infos` 防回潮~~ ✅ 已完成——CI 现以 `flutter analyze --fatal-infos` 收口，零告警
- **M4 README/docs 重写**：README 讲清「这是什么（Throne 核心 + Flrone UI）／与上游关系／自更新与签名／安装升级」；去掉上游捐赠链接（保留上游致敬段）；`bbox-bridge.md`/`bbox-flutter.md` 对照 `Capabilities.kt` + 通道现状重写（通道方法以双端 grep 为准）；**本规划文档随此批入库 `docs/roadmap.md`**
- **M5 通道契约自动化**：新 `tools/diagnostics/channel_audit.py`——正则扫 Dart `box.call('…')/events.add({'type':…})` 与 Kotlin `when(call.method)/emit("…")`，双端差集为空才算过；进 CI（ci.yml 加一步）
- 验收：M5 脚本 0 差集；CI 带 --fatal-infos 全绿；README/docs 与实况一致

### W3 · 批次 N：稳定性与可观测（v3.2.0）

- **N1 核心日志分层显示**：Flutter 日志页加「噪音折叠」——对已知良性核心错误（handshake-reset 类）默认折叠为计数徽章（「已折叠 N 条连接重置噪音」），可展开可关闭；**不改核心、不删记录**，只改展示层（openspec diagnostics-logging spec 补 delta）
- **N2 本地崩溃自捕获**：默认关闭的「诊断日志」开关（对应 Capabilities.reports 语义的轻量自建，**不上传**）——Thread.uncaughtExceptionHandler + ANR 观测落盘 app 私有目录，日志页可查看、可随日志导出；修复后保留 7 天滑动窗口
- **N3 真机验证矩阵（制度化）**：写 `docs/device-checklist.md`——arm64 真机：新装首启 / 覆盖升级（3.0.x→new）/ 备份导出→恢复（含 WebDAV）/ 分应用代理 / TV 模拟器 D-pad 全屏走查 / 弱网切换。**每个里程碑发版前跑一轮**，结果记入 CHANGELOG 节尾（「已过设备清单 YYYY-MM-DD」）
- **N4 自更新端到端演练**：本地起静态服务托管伪造 throne-update.json 验证 size/sha256 校验拒绝路径（UpdateVerifier 已有实现，缺的是恶意/损坏包拒绝的自动化验证）
- 验收：N1 折叠生效可还原；N2 崩溃可复现可导出；N3 清单执行一轮并留档；N4 拒绝路径有测试

### W4 · 批次 O：首个 B-box 独有能力（v3.3.0，二选一）

按价值/风险/核心依赖三轴评估后**只做一项**（下表是 11-03 的初评，结论已被下方 11-05 复核推翻）：

| 候选 | 价值 | 依赖 | 建议 |
|---|---|---|---|
| `quality` 网络质量采样页 | 直观展示各节点长期质量 | 核心 clash API 数据已有（`BboxApi`）；主要是采样存储 + 图表 | 初评首选 → **复核后撤销** |
| `capture` HTTP 捕获改写 | 高级调试利器 | 依赖 libbox 私有引擎，Throne 核心是否暴露**未证实** | 侦察失败 → **不立项** |
| `dnsObject` 裸 DNS 编辑器 | 高级用户刚需 | 纯 JSON 引擎已就绪（批次 E），加 schema 即可 | 备选 → **已由 DNS 设置页实现** |

**侦察结论（2026-11-05 复核，quality 立项撤销）：**

2026-11-03 写的「核心暴露 NetworkQualityTest 族」经不起复核。逐项核对如下：

| 检查项 | 事实 |
|---|---|
| 固定核心 `THRONE_CORE_REF=36b6bc4` | `core/mobile` 只导出 `StartURLTest` / `StartIPTest` / `StartSpeedTest`；全仓 `grep -i networkquality` 零命中 |
| 上游 `dev` @ `a973efe`（2026-11-05 拉取） | 同上，仍无 quality 相关导出 |
| `capture` 前置条件 | 同样不成立：`core/mobile` 没有请求捕获/改写入口，`CaptureDiagnostics` 只是性能采样 zip，与 HTTP 捕获无关 |
| `dnsObject` 备选 | **已经实现**：`useDnsObject` + `SettingJson('DNS object')` 在 DNS 设置页（`pages/throne.dart`），`SettingsSchema` 以 `Apply.Reload` 落地；`Capabilities.dnsObject` 只控制一个并不存在的 B-box 独立页 |

即：三个候选里两个没有核心支撑、一个已经做完。**v3.3.0 必须重新立项**，不要照上表执行。

替代方向（筛选标准：核心已具备、宿主尚未接入）：

| 候选 | 核心入口 | 价值 |
|---|---|---|
| 域名解析预览 | `ResolveDomains(current, platform, request)`，宿主未用 | 排障时看清某域名在选定 outbound 下解析到什么，与 DNS 设置页配套 |
| Xray 配置校验 | `CheckXrayConfig`，宿主未用 | typed 表单保存前拦住非法 Xray 配置 |
| WireGuard 密钥生成 | `GenerateWireGuardKeyPair`，宿主未用 | 端点/自建 WG 配置不必外部生成密钥 |

quality 页若一定要做，只能改成**应用侧自研采样**（TUN 下普通 HTTP 即走隧道）：可以落地，但 Dart 侧无法指定出口，`outbound` 选择器只能去掉，口径也与 B-box 的核心采样不同，必须在页面上标注差异——不适合当作"独有能力"宣传。

**落地记录（2026-11-05，v3.3.0 = 域名解析预览）：**

- 链路：`dns.resolve`（Dart）→ `BboxResolve` → `ICoreService.resolveDomains` → `DomainResolver`（:bg）→ `Mobile.resolveDomains`，结果按请求顺序回 `{domain, addresses, error}`
- 语义按核心的实际约束写死：解析固定走运行中实例的 `dns-direct`（杀开关会挡系统解析器，Tun 的 fakeip 会把系统答案换成本地假地址），**未连接时返回 `running=false`**，不用手机解析器的结果冒充隧道答案；32 个域名、16 并发、单条 5 s
- UI：`pages/resolve.dart` 挂在「设置 → 诊断」，`Capabilities.dnsResolve` 为 true 才出现；这是诊断菜单里目前唯一可用的入口（quality/stun 仍为 false）
- 覆盖：`DomainResolverTest`（wire 契约 + 容错）、`domain_resolve_test.dart`（含 codec 形状）、`navigation_test` 增加该页在 3 种视口/主题下的渲染

流程：重新立项后仍走 openspec 提案（proposal + tasks + spec delta）→ 桥接层 → Flutter 页 → `Capabilities.kt` 置 true → 设备清单过 N3。其余 false 项（terminal/taildrop/endpoints/remote/stun/perAppManaged/rootQuery）**明确不做**（重依赖或低价值），除非用户点名。

### W5 · 上游跟踪（常驻，不占版本号）

- 每月核对 `throneproj/Throne` 新 release/commit：安全修复与核心 bugfix **及时 pin 升级**；升级动作 = 改 `THRONE_CORE_REF` → CI 重建 AAR（缓存失效）→ 全量测试 + N3 设备清单 → 单独发 patch 版
- 关注上游破坏面：sing-box option schema（影响 JSON 引擎资产与 typed 表单字段）、clash API 形状（影响 dashboard/connections）、`THRONE_CORE_SCRIPT_SHA`（build_android.sh 变更使缓存键失效属正常）
- 上游若有 Flutter 化动向，评估 C 路线成本后再动

### W6 · 分发与合规（随 v4.0 评估）

- targetSdk 35→36 窗口（Android 16 要求）随上游/依赖就绪后走单独批次
- F-Droid / Play 上架评估：签名密钥管理（现为 GitHub secrets 的独立密钥）、隐私政策页（VPN 应用清单要求）、数据安全表单——**仅在用户提出上架需求时启动**
- APK 体积画像与预算：Flutter AAR + 多 ABI split 已就绪，补「每版体积记录进 CHANGELOG」的轻量惯例即可

### W7 · 治理与流程（常驻）

- **并行会话纪律**（11-03 事故固化）：同一工作区只允许一个 agent 会话执行写操作；第二会话只读或等待；操作前 `git branch -vv` + 文件 mtime 检查；提交只 add 自己的文件；main 前进用 `git branch -f` 不 checkout
- 删除类改动（退役代码、删分支、删 release）一律 `git grep` 逐引用核对 + CI 验证（仓库已有三次删错事故先例）
- 每里程碑双 agent code review 固化；review 发现 <80 分但 ≥75 的项必须在 CHANGELOG 或 issues 里留痕（不许静默丢弃）
- renovate/dependabot 评估：Kotlin 依赖可自动，Flutter 侧注意 pubspec.lock 必须保持 pub.dev（镜像污染已有三次）

---

## 4. 里程碑与发版

| 版本 | 内容 | 前置 | 发布动作 |
|---|---|---|---|
| **v3.0.12** | ✅ W1 日志轮收尾（2026-11-03 发，commit `41636a9`） | — | 已发，latest 已指向 |
| **v3.1.0** | ✅ 批次 M + N 合并发版（含 analyze 清零、README/docs、通道审计、噪音折叠、崩溃存储、设备清单、更新拒绝测试；双 agent 评审 18 项） | — | 已发，latest 已指向 |
| **v3.2.4** | ✅ 体积与运行时过一遍：R8 精确 keep + full mode、Twemoji 删除/字体子集/图标 WebP、~~`useLegacyPackaging=false`~~（3.2.4 尝试后回退，`app/build.gradle.kts` 现为 `useLegacyPackaging = true`）、GC debug-only、Jetifier 关闭 | — | 见 `openspec/changes/2026-11-03-size-pass/` |
| **v3.2.15** | ✅ 冗余代码清理批 R1+R2.1+R4（旧偏好 UI 层 16 xml/6 类/3 支撑类 + proguard keep 收窄、12 个死 Kotlin 整文件、2 个 Dart 孤儿 + `flutter_localizations` 降为传递依赖）；R2.2/R4.3 经复核为误判未执行，R3 资源瘦身待 lint UnusedResources 前置复核 | 计划复核 | 单独 patch 发版 |
| ~~v3.2.0~~ | 并入 v3.1.0（N 批次随 M 同轮落地） | — | — |
| **v3.3.0** | ✅ 批次 O 改为**域名解析预览**（`dns.resolve`，原 quality/dnsObject 两个候选经复核不可行，见 W4）；`dnsResolve` 能力置 true | 核心 `ResolveDomains`（已具备） | 单独发版 |
| **v3.4.0** | 工具链解钉（`docs/toolchain-upgrade.md` U1→U2，U3 可随附） | U1/U2 前置链 | 单独评审轮 + N3 设备清单 |
| **v4.0.0** | 核心大版本跟随 + targetSdk 36 + 上游 schema 适配 | 上游 release 节奏 | 单独评审轮 |
| 常驻 | W5 上游 pin 升级（每个安全修复） | 无 | patch 版 |

发布前固定动作：CHANGELOG 节存在性（release_notes.sh 会拦）→ tag 查重（`gh api .../releases/tags/vX.Y.Z`）→ dispatch → 核对 prerelease 标志 / assets / latest。

---

## 5. 风险清单

1. **上游破坏性演进**（最高）：schema/option/clash API 变更会同时打穿 JSON 引擎、typed 表单、dashboard——缓解：M5 审计脚本 + 每次 pin 升级全量回归；schema 资产随 CI throne-core 步骤自动再生成是既有安全网
2. **AAR 依赖链隐形升级**：Flutter 工具链升级（3.47.9→未来）可能引入 coroutines/stdlib 新 API 引用，配合 force pin 出运行时崩溃——缓解：M1 收窄结论 + 升级 Flutter 时必跑 N3 设备清单
3. **删除类事故**：历史三次（删错 Kotlin 分支、checkout 丢挂载、pubspec.lock 污染）——缓解：W7 治理三条
4. **单维护者 + agent 流水线的吞吐瓶颈**：CI 一轮 ~12 分钟，批次滚动依赖结果——缓解：批次间并行做文档/侦察类只读工作
5. **验证盲区**：CI 只能证「构建得出、测试过」，证不了「真机好用」——缓解：N3 制度化，不接受「CI 绿 = 可发版」的捷径

---

## 6. 进度跟踪约定

- 每批完成：openspec 立/勾对应提案（`openspec/changes/<批次号>-<主题>/`），提交说明带批次号前缀（如 `批次 M3:`）
- 本文档随执行修订：批次完成即更新 §4 里程碑表状态；与仓库实况冲突时以实况为准，先修订再执行
- 完成迁移归档后，本规划的历史使命结束时（预计 v4.0 后），按同格式写下一期规划并归档本文至 `openspec/history/`
