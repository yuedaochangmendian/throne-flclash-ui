# Flrone（Throne for Android）· 简体中文简介

> 完整英文版见仓库根目录 [README.md](../README.md)；英文精简版见 [README_en.md](README_en.md)。

## 项目定位

Flrone 是一款 Android 平台上的图形界面代理工具，基于 [sing-box](https://github.com/SagerNet/sing-box) 内核（上游为 throneproj/sing-box 分支，并与 Xray-core 配合）。它沿用 Throne 的引擎与数据模型，界面则整体替换为 Flutter 实现（改编自 FlClash 的 prism UI 层 / B-box 界面）。支持 Android 7.0（API 24）及以上，并支持 Android TV。本仓库以 GPL-3.0 许可发布。

## 与上游 Throne 的关系

本仓库是 [throneproj/ThroneForAndroid](https://github.com/throneproj/ThroneForAndroid) 的**下游发行版**：核心（sing-box + Xray、协议与配置面）按 `nb4a.properties` 中的 `THRONE_CORE_REF` 逐版本固定、由 CI 构建；界面、桥接层与发布线由本仓库维护。上游自身的发行版、文档（throneproj.github.io）与捐赠渠道仍在上游仓库，本仓库不提供这些。

## 下载

请到 [GitHub Releases](https://github.com/yuedaochangmendian/throne-flclash-ui/releases) 下载。每个版本提供三个 ABI 分包（arm64-v8a、armeabi-v7a、x86_64），并附带 `SHA256SUMS`；应用内更新会先校验文件大小与 SHA-256 再提示安装。自 v2.0.0 起签名密钥与 1.x 不同，从旧版升级需先卸载再安装并重新导入订阅。

## 三条最重要的特性

1. **与 Throne 桌面端一致的数据模型**：分组与订阅（按组过滤、更新后测速、定时更新）、共享的路由配置、`.thrbackup` 备份格式（桌面端与移动端互通，可经 WebDAV 同步）。
2. **Flutter 单一界面**：内置 sing-box 仪表盘（实时流量、连接、日志）、批量测速面板、sing-box 感知的 JSON 编辑器，以及桌面小部件、快捷设置磁贴、Android TV 遥控器导航。
3. **可校验的分发与自更新**：三 ABI 分包、`SHA256SUMS` 与 `throne-update.json`（含签名证书 `signerSha256`），由发布流程统一生成。

## 反馈

请通过 [GitHub Issues](https://github.com/yuedaochangmendian/throne-flclash-ui/issues) 反馈问题与建议（提 bug 时请附上导出的日志并去除敏感信息）。涉及尚未公开的安全漏洞请按 [SECURITY.md](../SECURITY.md) 私下报告。贡献前请先阅读 [CONTRIBUTING.md](../CONTRIBUTING.md)。
