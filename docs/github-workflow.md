# GitHub 流程规范

本文是仓库在 GitHub 上的**唯一流程基准**：分支、PR、发版、tag、release、更新器契约与 CI 职责。`CONTRIBUTING.md` 第 3 节与 `docs/release-runbook.md` 是它的执行细则，冲突时以本文为准。配置真源是仓库内文件（`nb4a.properties`、`.github/workflows/`、`buildScript/`），本文不复制具体数值，只固定规则。

配套自动校验：`tools/diagnostics/github_governance.py`（`Repository governance` workflow 定时运行）。**新增违规会阻断，历史遗留列在 `github_governance_baseline.json`，修复一项就从基线删一项。**

## 1. 分支模型

| 规则 | 要求 |
|---|---|
| 发布基线 | `main` 是唯一基线；只接受 PR 合并，禁止直接推送提交（`CONTRIBUTING.md` 已规定） |
| 分支命名 | `feat/*`、`refactor/*`、`fix/*`、`docs/*`、`build/*`、`chore/*`、`dependabot/*`；禁止 `wip-*`、`tmp-*`、日期分支、个人名分支 |
| 起点 | 从最新 `main` 创建；长期开发线需定期 rebase `main`，不得与基线长期分叉 |
| 收口 | 一个 PR 对应一个自洽改动；超过约 20 提交的线应拆成可独立审查的 PR |
| 合并后 | 删除源分支（仓库设置 `delete_branch_on_merge=true`）；已合并分支不留残枝 |
| 保护 | `main` 应配置保护：禁止强制推送与删除、要求经 PR、要求 CI 全绿。**启用前必须确认 CI 依赖可用**，否则会把 `main` 锁死（见第 7 节） |

> **当前偏差（2026-11-08）**：`main` 无分支保护，`CONTRIBUTING.md` 第 3 节要求的 PR-only 目前靠约定而非仓库设置强制。3.3.1 开发线已于同日以 PR #11 合回 `main`（原偏差已收口，见第 9 节）；`v3.3.1-pre.*` 的 tag 仍指向合并前的提交，属已发布历史的正常结果，不回填。

## 2. Pull Request

- 填写 `.github/PULL_REQUEST_TEMPLATE.md` 的全部验证清单；涉及桥接方法／事件时同步 Dart 与 Kotlin 两端并核对 `docs/bbox-bridge.md`、`Capabilities.kt`。
- 合并前 CI 全绿（`ci.yml`：Kotlin 单测与 debug 构建、Flutter analyze / test / 覆盖率下限、`channel_audit`、`symbol_audit`、`settings_audit`、`ffi_regression_test`、`generated_models_check`、`py_syntax_check`、cgo preamble、AAR API 扫描、Prism drift）。
- 依赖升级由 `dependabot.yml` 每周发起；合并前确认不引入 SDK / AGP / Kotlin 版本跨越，关闭时不留分支。
- CI 因外部依赖故障变红**不等于代码不合格**；按第 7 节处理，不得为凑绿而跳过签名、校验或直接推送 `main`。

## 3. 版本与发版通道

**唯一真源**：`nb4a.properties` 的 `PACKAGE_NAME` / `VERSION_NAME` / `VERSION_CODE` / `THRONE_CORE_REF`。构建号只由 workflow 注入（`THRONE_CHANNEL`、`THRONE_BUILD`），不得手改 APK 元数据。

| | preview | stable |
|---|---|---|
| tag | `vX.Y.Z-pre.N`，`N = 1..998`（距上一个 stable tag 的提交数） | `vX.Y.Z` |
| 触发 | `preview.yml`（`workflow_dispatch`，临时产物）或推送 `v*pre*` tag 走 `release.yml` | 推送 `vX.Y.Z` tag 或 `release.yml -f publish=true` |
| `versionName` | `X.Y.Z-pre.N` | `X.Y.Z` |
| `versionCode` | `VERSION_CODE*1000 + N` | `VERSION_CODE*1000 + 999` |
| GitHub 标记 | `prerelease=true`，**不占 `releases/latest`** | `prerelease=false`，`make_latest=true` |
| 资产 | 3 个 ABI APK + `SHA256SUMS`，**不得有 `throne-update.json`** | 3 个 ABI APK + `SHA256SUMS` + **`throne-update.json`**（5 个） |
| 应用内更新 | 不推送（应用内更新器读 `releases/latest`） | 通过 `throne-update.json` 推送 |

- `release_assets.py` 会拒绝 `channel` 与 `versionName` 不匹配、签名者不唯一、ABI 缺失；CI 的 `Changelog` 步骤会拒绝缺少 `#### <version>` 段落的 CHANGELOG。**发版前必须先写 CHANGELOG 段落**。
- 一个 tag 对应一个 release；tag 不复用、不改名、不删除重建。
- `release.yml` 的 `Version` 步骤会校验 tag 基础版本与 `nb4a.properties` 一致、tag 未被占用；`publish_release.sh` 对每次写操作重试 3 次并保留 `dist/` 供降级补发。

## 4. tag 与 release 命名

- 允许：`^v\d+\.\d+\.\d+(-pre\.\d+)?$`。禁止 `wip-*`、`*-debug`、`*-bbox-ui-*`、日期 tag 等非正式命名。
- 调试 / 临时构建只上传为 workflow artifact（保留 14 天），**不创建 release、不打 tag**。
- `releases/latest` 只能由资产齐全的 stable release 占用；预览版转正属异常路径（第 7 节），不得常态化。
- release 的 `name` 与 `tag_name` 保持一致；若就地转正导致不一致，必须在发行说明里写明真实 tag 与产物性质。

> **当前偏差（2026-11-08）**：`releases/latest` 指向 `v3.3.1-pre.23`（`name` 为 `v3.3.1`），是 CDN 故障期间就地转正的结果；产物仍是 preview 通道构建（`PREVIEW=true`、`versionCode=161023`）。另有 6 个 2026-11-01 的 debug 构建曾被标为 stable、5 个历史 preview release 误带 `throne-update.json`、3 个 `wip-bbox-*` tag 无 release。均已列入治理基线。

## 5. 更新器与签名契约

- `UpdateChecker.REPOSITORY` **必须指向本仓库** `yuedaochangmendian/throne-flclash-ui`；常量曾指向上游 `throneproj/ThroneForAndroid`，导致本仓库发布的 `throne-update.json` 根本不被应用内更新器读取。本次已在 `main` 修复（此前另在 `feat/ffi` 修过一次，该分支已合并删除），**已发布 APK 需重新构建才生效**。
- `throne-update.json`（`schema=1`）字段：`packageName`、`channel`、`versionName`、`versionCode`、`coreRef`、`minSdk`、`signerSha256`、`assets`（每个 ABI 的 `name` / `size` / `sha256`）。三个 ABI 必须同一签名者、同一 `versionCode`，且与实际 APK / `SHA256SUMS` 一致。
- 签名固定值来自仓库 secrets，发布前按 `SIGNING-POLICY.md` 核对 `signerSha256`；`UpdateVerifier` 会校验文件大小、SHA-256、包名、`versionCode` 递增、签名一致与 pin。
- `release_assets.py` 只在 stable 通道生成清单；preview 产物不得携带清单。

## 6. workflow 职责边界

| workflow | 触发 | 职责 | 对外产物 |
|---|---|---|---|
| `ci.yml` | push / PR | 静态分析、单测、契约审计 | 无（报告 artifact） |
| `release.yml` | `workflow_dispatch` / push `v*` tag | 构建、签名、生成 5 个资产、创建 release | GitHub release |
| `preview.yml` | `workflow_dispatch` | 用 `.debug` 包名做临时预览，**不创建 release/tag** | workflow artifact |
| `governance.yml` | 定时 / 手动 / 治理文件改动 | 校验仓库状态是否符合本文 | Step Summary |

`preview.yml` 与「推送 `v*pre*` tag 发预览版」是两条不同通道：前者只出临时 APK，后者出正式 GitHub prerelease。需要可安装的预览版时走 `release.yml`，不要用 `preview.yml` 的产物冒充 release。

## 7. 降级路径（外部依赖故障）

- GitHub releases 下载端点可能返回 504（2026-11-08 的 `kotlin-compiler-embeddable-2.2.21.jar` 持续故障），导致 `ci.yml` / `release.yml` 的 Gradle 构建失败。**这是外部故障，不是代码问题**；`Repository governance` 不依赖 Gradle/NDK/Flutter，仍可运行。
- 已构建并签名的产物由 `publish_release.sh` 保留为 `Flrone-<tag>-publish-failed` artifact；按 `docs/release-runbook.md` 的本地补发路径收口（草稿按 release id 查询、`target_commitish` 写目标 sha、资产走 `uploads.github.com`）。
- 需要读取 release 资产时，`api.github.com/repos/.../releases/assets/<id>` 的 302 `Location`（`release-assets.githubusercontent.com` 签名直连）通常仍可用，可配合 HTTP Range；不要因为 `github.com/.../releases/download/` 返回 504 就判定资产丢失。
- **就地转正**仅作为 CI 完全不可用时的临时手段，且必须：补 `throne-update.json`、改 `prerelease=false` + `make_latest=true`、重写发行说明并明确标注 APK 仍是 preview 构建；CDN 恢复后补发标准 stable 版本并在 CHANGELOG 补对应段落。

## 8. 治理校验

`github_governance.py` 用 GitHub API 只读检查：分支命名、tag 命名、tag↔release 一一对应、stable 资产齐全、preview 不带清单、`releases/latest` 合法、`UpdateChecker.REPOSITORY` 指向本仓库、`nb4a.properties` 与 CHANGELOG 顶部段落一致、仓库 `delete_branch_on_merge` 已开启。`delete_branch_on_merge` 属 admin 级字段，CI 的 `github.token`（`contents: read`）读不到时该项跳过、不误报；用维护者 PAT 本地运行时会实际校验。

- `--strict`：存在**不在基线内**的违规时退出 1；`Repository governance` 以 strict 运行并写入 Step Summary。
- 基线 `github_governance_baseline.json` 只收录已确认的历史遗留；每修复一项就删除对应 id，使校验重新对该项生效。
- 本地运行：`GH_TOKEN=<token> python3 tools/diagnostics/github_governance.py --repo <owner/repo> --format markdown`。

## 9. 待收口项（需维护者决策）

| 项 | 现状 | 建议动作 | 影响 |
|---|---|---|---|
| `main` 分支保护 | 无保护、无 ruleset | CI 恢复后配置：禁强推/删除、要求 PR 与 CI 全绿 | 高，启用早于 CI 恢复会锁死 `main` |
| 标准 `v3.3.1` | 未发；当前 latest 是转正的 preview 构建 | CDN 恢复后按第 3 节补发，tag 用干净 `v3.3.1` | 高，会产生新 release |
| CHANGELOG `#### 3.3.1` | 缺失 | 在发版分支补写正式版段落 | 中 |
| 6 个 debug release | 曾标 stable、资产不齐 | 已改标 `prerelease`（可逆）；或删除 | 中 |
| 5 个 preview 带清单 | v3.2.18–v3.2.22 | 移除 `throne-update.json` 资产，或列入基线保留 | 中 |
| 3 个 `wip-bbox-*` tag | 无对应 release | 删除调试 tag | 低 |
| 已合并残枝 / 陈旧 dependabot PR | 分支保留、PR #6/#9 开放、PR #16 已随基线变更改指向 `main` | 清理分支、关闭或合并 PR | 低 |

**已收口（2026-11-08）**：PR #11 以 merge commit `05ef51b7` 合入 `main`（62 提交、115 文件、+9543/−1882），`main` 自此是 3.3.1 基线，`VERSION_NAME` 由 3.3.0 变为 3.3.1。`feat/ffi` 随 `delete_branch_on_merge` 一并删除，其内容已在 `main` 上，后续 `feat/*` 从 `main` 切出。真机走查（`docs/device-checklist.md`）仍未做，须在补写 CHANGELOG `#### 3.3.1` 正式段落前完成。
