# 安全政策（Security Policy）

## 报告漏洞

请勿在公开 Issue、讨论区或 Pull Request 中披露尚未修复的安全问题。请通过以下私有渠道之一报告：

- **GitHub Security Advisories**：在本仓库的 Security → Report a vulnerability 私下提交（<https://github.com/yuedaochangmendian/throne-flclash-ui/security/advisories/new>）；若该入口不可用，请通过仓库 Security 页或请求维护者开启仅报告者可见的私有渠道跟进。
- 或请求维护者开启一个仅报告者可见的私有 Issue。

目前不提供专用安全邮箱，请勿把漏洞细节发送到任何公开渠道。报告时请尽量附上受影响版本、复现步骤、影响范围与（如有）建议的修复方式。

## 支持版本范围

安全修复只针对**当前最新的稳定发行版**（版本号见 `nb4a.properties` 的 `VERSION_NAME` 与 [GitHub Releases](https://github.com/yuedaochangmendian/throne-flclash-ui/releases)）。旧版本不再单独获得修复，建议升级到最新版；preview 通道的产物不在此范围内。

## 回应预期

本仓库由个人／小团队维护，无法承诺固定的响应或修复时限。维护者会尽力确认报告、在私有渠道回复进展，并在确认后按需发布修复版本、于 `CHANGELOG.md` 中记录。若较长时间未收到回复，可在同一私有渠道追加一次提醒（仍请勿公开细节）。

## 遥测与数据

**本项目不收集遥测。** 就当前仓库代码与文档而言，应用不内置向维护者或第三方自动上报用量、崩溃或设备数据的通道；日志与诊断信息保存在本地，导出由用户在应用内主动触发（见 `README.md` 的 Log 段与 Issue 模板中「导出日志」的说明）。`docs/roadmap.md` 中的本地诊断日志设计也标注为「不上传」。

若未来版本引入任何数据收集行为，会先在本文件与 `CHANGELOG.md` 中说明，再随发行版发布。
