# Repository Governance Specification

## Purpose

定义 Flrone（throneproj/ThroneForAndroid 的下游发行版）的仓库边界、规范来源、构建协作方式、版本与核心来源以及发布工作流，避免项目知识和维护约定随人员或大版本更替再次散落。

## Requirements

### Requirement: OpenSpec 是当前规范的唯一入口

仓库当前有效的架构、功能约束和协作规则 MUST 维护在 `openspec/specs/` 的主规范中。新增或修改项目结构、关键模块、协议、配置、构建流程或维护工具布局时，实施改动 MUST 同步更新受影响的主规范。已完成的大型迁移记录 MAY 保存在 `openspec/history/`，但 MUST NOT 被当作尚待执行的 change。

#### Scenario: 架构改动同步规范

- **WHEN** 一次实现改变了核心接驳、Android 关键模块、构建链或工具目录
- **THEN** 对应的 `openspec/specs/` 主规范已同步反映新状态
- **AND** 历史记录仅承担背景和决策追溯职责

### Requirement: 仓库目录职责明确

仓库 MUST 按以下边界组织：`app/` 承载 Android 应用，`buildScript/` 与 `buildSrc/` 承载构建辅助逻辑，`gradle/` 承载 Gradle Wrapper，`.github/` 承载 GitHub 自动化（可复用的构建步骤以 `actions/` 下的复合动作组织），`openspec/` 仅承载 OpenSpec 配置、规范、变更和历史资料，`tools/diagnostics/` 承载仓库维护用诊断脚本。OpenSpec 运行目录中 MUST NOT 放置项目诊断程序或其运行产物。

#### Scenario: 添加维护工具

- **WHEN** 一次性调研、格式解析或静态校验程序需要纳入仓库供后续复用
- **THEN** 程序被放入 `tools/diagnostics/`
- **AND** `.roo/` 与 `openspec/` 中没有新增该程序

### Requirement: Python 工具使用 uv 文件工作流

仓库维护用 Python 代码 MUST 先写入 `tools/diagnostics/` 下的 `.py` 文件，再从仓库根目录使用 `uv run tools/diagnostics/<script>.py [arguments]` 执行。维护流程 MUST NOT 使用 `python`、`python3` 或 `python -c` 直接执行项目辅助代码。脚本若需要定位仓库根目录，MUST 从脚本路径推导（例如 `Path(__file__).resolve().parents[2]`）。

#### Scenario: 执行临时分析

- **WHEN** 需要用 Python 扫描或转换仓库内容
- **THEN** 完整逻辑先保存为 `tools/diagnostics/` 下的脚本并使用 `uv run` 执行
- **AND** 不通过命令行内联 Python 代码

### Requirement: 本地开发不依赖 Go 或 Android 编译环境

开发流程 MUST 假定本地未安装 Go 环境且未克隆核心源码。AI/开发者 MUST NOT 要求用户在本地编译核心 AAR 或 Android APK；可执行不依赖这些环境的静态校验。核心 AAR、Android APK 和真机行为 MUST 由 GitHub Actions 与用户真机验证。外部依赖的源码、版本和 API 定义 SHOULD 通过官方网络来源查询。

#### Scenario: 验证跨核心与 Android 的修改

- **WHEN** 一次修改影响核心或 Android 编译
- **THEN** 本地只运行可用的静态检查
- **AND** 最终编译交由 GitHub Actions，运行时行为交由真机验证

### Requirement: 核心由 CI 按 THRONE_CORE_REF 构建并缓存

throne 核心 MUST 以 `nb4a.properties` 的 `THRONE_CORE_REF` 为唯一真实来源。CI MUST 从该 ref 检出 `throneproj/Throne` 构建 `ThroneCore.aar` 并生成 Android 构建标签一致的 sing-box 选项 schema，两者 MUST 以解析后的核心 commit 与核心构建脚本哈希为缓存键。核心 ref 或构建脚本变化 MUST 使缓存失效。

#### Scenario: 升级核心 ref

- **WHEN** 维护者修改 `nb4a.properties` 的 `THRONE_CORE_REF` 并触发构建
- **THEN** CI 检出并构建对应核心 commit，重新生成 AAR 与 schema
- **AND** 旧缓存不再被复用

### Requirement: 外部仓库由用户提供明确路径

开发过程中若需要参考外部仓库的本地副本，AI/开发者 MUST 先告知用户所需仓库及参考目的，由用户提供具体路径。AI/开发者 MUST NOT 自行遍历、搜索或猜测用户机器上的其他项目目录，也 MUST NOT 将其中未获用户明确指定的项目视为可用参考资料。

#### Scenario: 实现需要参考外部仓库

- **WHEN** 仅凭本仓库内容和官方网络来源无法可靠完成实现
- **THEN** 先向用户说明所需仓库及参考目的并等待其提供具体路径
- **AND** 仅访问用户明确提供的路径

### Requirement: 应用版本来源唯一

应用版本 MUST 以 `nb4a.properties` 的 `VERSION_NAME`（及 `VERSION_CODE`）为唯一真实来源；包名 MUST 以 `PACKAGE_NAME` 为准。发布物（tag、Release 标题、预览版本号）MUST 随该值派生，避免构建与发布版本错位。

#### Scenario: 升级应用版本

- **WHEN** 维护者修改 `nb4a.properties` 的 `VERSION_NAME` 并发布
- **THEN** 构建产物、发布 tag 与标题均使用新版本号

### Requirement: 发布与预览工作流分离

GitHub Actions MUST 通过 `release.yml` 与 `preview.yml` 分离正式发布与预览构建。正式发布 MUST 仅允许手动触发，MUST 从 `nb4a.properties` 的 `VERSION_NAME` 派生 tag `v${VERSION_NAME}`；当该 tag 已存在时 MUST 构建失败并提示提升版本号，而不复用旧 tag。发布入口 MUST 支持仅产出 workflow artifact 不创建 Release 的模式。预览 MUST 在推送到主分支时自动构建，版本号 MUST 为 `v${VERSION_NAME}-pre.${N}`（N 为自最近一个正式 tag 起的提交数，上限 998，保证预览排序低于对应正式版），HEAD 恰为正式 tag 时 MUST 跳过预览，且 MUST 以 pre-release 形式发布。

#### Scenario: 手动发布正式版本

- **WHEN** 维护者手动运行 Release 工作流且允许发布
- **THEN** 工作流构建签名 APK 并创建 `v${VERSION_NAME}` 的 GitHub Release 并附加产物

#### Scenario: 版本号未提升时拒绝发布

- **WHEN** 目标 `v${VERSION_NAME}` tag 已存在于远端
- **THEN** 工作流失败并提示提升 `VERSION_NAME`，不覆盖旧 Release

#### Scenario: 主分支推送触发预览

- **WHEN** 提交推送到主分支且 HEAD 不是正式 tag
- **THEN** 工作流按提交数生成预览版本并发布 pre-release
- **AND** HEAD 为正式 tag 时不发布预览
