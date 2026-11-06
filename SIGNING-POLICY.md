# 签名策略（Signing Policy）

本文件说明本发行版 APK 签名密钥的保管、发布约束与用户侧校验方式。文中提到的脚本、字段与流程均对应仓库内真实存在的实现：`buildScript/release_assets.py`、`.github/workflows/release.yml`、`.github/actions/android-build/action.yml`、`docs/release-runbook.md`、`README.md`。

> 说明：本文是策略声明，不是对已有配置的自动校验结果。分支保护规则、tag 保护与账号两步验证（2FA）在 GitHub 仓库／账号设置侧维护，仓库内不包含这些配置文件；下文第 2、3 节中的「要求」是对维护者的约束，而非声称某处已自动生效。

## 1. 密钥保管

发布签名在 GitHub Actions 中完成，密钥不以明文进入仓库。`.github/workflows/release.yml` 的 `release` job 从仓库 secrets 注入四个环境变量：

| Secret | 用途 |
|---|---|
| `SIGNING_KEYSTORE_B64` | 签名 keystore 的 Base64 内容 |
| `SIGNING_STORE_PASSWORD` | keystore 口令 |
| `SIGNING_KEY_ALIAS` | 密钥别名 |
| `SIGNING_KEY_PASSWORD` | 密钥口令 |

`.github/actions/android-build/action.yml` 在 `sign=true` 时把 `SIGNING_KEYSTORE_B64` 解码到 runner 临时目录（`RUNNER_TEMP/release-signing.keystore`），用 `keytool -exportcert … | sha256sum` 计算证书 SHA-256 并作为 `UPDATE_SIGNER_SHA256` 交给构建，随后删除临时文件；四个 secret 缺失时构建直接失败。要求：

- 这四项只保存在 GitHub Actions secrets 中，禁止提交进仓库、写入日志或随 artifact 分发；
- 仅仓库维护者持有 secret 的写入权限；keystore 原件离线保管。

## 2. 发布权限与 tag 保护

- 发布工作流 `release.yml` 由 `workflow_dispatch`（`publish` 布尔输入，默认 `true`）或推送 `v*` tag 触发；tag 名为 `v` + `nb4a.properties` 中的 `VERSION_NAME`。
- 工作流在发布前用 `git ls-remote --exit-code --tags origin` 检查同名 tag 是否已存在，已存在的 tag 不会复用；发布说明取自 `CHANGELOG.md` 对应版本段落（`buildScript/release_notes.sh`），缺失会先失败。
- `PUBLISH=false` 时只构建并上传 artifact，不创建发行版。发布失败时另有 `Flrone-<tag>-publish-failed` artifact 保底，避免丢失已签名 APK（见 `docs/release-runbook.md`）。
- 要求（策略）：仅维护者可触发 `workflow_dispatch` 并推送 `v*` tag；应对 `v*` tag 启用保护规则、限制谁可创建／删除 tag，并对默认分支要求合并前 CI 通过。具体规则在 GitHub 仓库设置中维护。

## 3. 2FA 要求

要求（策略）：所有具备发布权限、可管理 secrets 或可推送 tag 的账号必须启用两步验证（2FA）；不得使用共享账号或共享 token 进行发布。此项为账号侧要求，仓库内不做技术校验。

## 4. 密钥泄露 / 吊销流程

由于签名密钥保存在 GitHub Actions secrets，泄露或需要轮换时的处理路径为：

1. 立即在仓库设置中轮换上述四个 `SIGNING_*` secrets，并暂停发布工作流；
2. 生成新的签名 keystore，更新四个 secret 与离线保管副本；
3. 用新密钥重新构建并发版，确认 `SHA256SUMS` 与 `throne-update.json` 中的 `signerSha256` 与新证书一致；
4. 通过 `CHANGELOG.md` 与发行说明告知用户签名变更。

注意：Android 要求同一应用包的覆盖安装使用相同签名证书。`README.md` 已记录 v2.0.0 起签名密钥与 1.x 不兼容、需卸载旧版后再安装并重新导入订阅；密钥再次轮换同样会导致覆盖安装失败，属于需要事先公告的破坏性变更，不应静默进行。

## 5. 用户如何核对 APK 签名

每个正式发行版由 `buildScript/release_assets.py` 从三个 ABI 的 APK 生成以下资产，并逐包校验（包名、版本、ABI、签名者数量与各包之间的一致性）：

- `SHA256SUMS`：每个 APK 的 SHA-256 与文件名；
- `throne-update.json`（仅 `stable` channel）：`signerSha256` 字段，值为 `apksigner verify --print-certs` 报告的签名证书 SHA-256 摘要；脚本要求每个 APK 恰好一个签名者，否则发布失败。

用户可按以下步骤核对（需 Android SDK build-tools 中的 `apksigner`）：

```bash
# 1. 校验下载文件的完整性（SHA256SUMS 由 release_assets.py 生成，格式为 "<sha256>  <文件名>"）
sha256sum -c SHA256SUMS

# 2. 查看 APK 的签名证书摘要
apksigner verify --print-certs <apk-file>
#    输出中的 "Signer #1 certificate SHA-256 digest: …" 即签名证书摘要

# 3. 与自更新清单比对：打开 throne-update.json，核对 signerSha256 与第 2 步的摘要一致
```

三个 ABI 的 APK 应得到相同的 `signerSha256`；任一不一致都说明该 APK 不是由本发行版同一密钥签发，请勿安装。`README.md` 的 Install and update 段说明应用内更新检查会校验文件大小与 SHA-256 后再提示安装。
