# 发布手册与 GitHub API 5xx 降级路径

> 完整流程规范见 [github-workflow.md](github-workflow.md)：分支模型、preview/stable 双通道、tag 与 release 命名、更新器契约、治理校验。本文只记发版操作与降级路径。

## 正常流程

1. 在 `nb4a.properties` 递增 `VERSION_NAME` / `VERSION_CODE`，在 `CHANGELOG.md` 顶部补对应版本段落（`buildScript/release_notes.sh` 会从这里取正文，缺失会在构建前失败）。
2. 推送到 `main`，等 CI 全绿（Kotlin 单测 + debug 构建 + cgo preamble 检查 + `flutter analyze --fatal-infos` + `flutter test --coverage` + 各契约审计）。
3. 触发发布：
   - 预览：`gh workflow run release.yml --ref main -f channel=preview`，创建 `v<VERSION_NAME>-pre.N` GitHub prerelease（同正式包名，无 `throne-update.json`）
   - 正式版二选一：`gh workflow run release.yml --ref main -f channel=stable -f publish=true`，或推送 `v<VERSION_NAME>` tag（工作流监听 `push.tags: v*`）
4. `buildScript/publish_release.sh` 负责创建/复用发行版：每次写操作重试 3 次（间隔 15s），已存在的 release/draft 改为上传资产并取消草稿，最后打印资产清单。
5. 核对：`gh release view <tag> --json tagName,name,isPrerelease,isDraft,targetCommitish,assets`。stable 必须非 prerelease、名称等于 tag、5 个资产齐全（3 个 ABI APK + `SHA256SUMS` + `throne-update.json`）；preview 必须标记 prerelease、名称等于 tag，且不得带 `throne-update.json`。

只想要 APK、不创建 Release 时，用 `release.yml -f channel=preview|stable -f publish=false`，产物以 `Flrone-<tag>` artifact 上传（保留 14 天）。发布失败时工作流保留 `Flrone-<tag>-publish-failed` 兜底 artifact。

## 当 runner 侧 GitHub API 返回 502 / 500

2026-11-04 的 v3.2.17 连续两次在 `gh release create` 因 runner 侧 502、500 失败，而构建、签名、`release_assets.py` 全部成功；同一时刻从本地调用 `api.github.com` 却正常。因此：

- 工作流现在会给失败的发布加上 `Flrone-<tag>-publish-failed` artifact，**签名 APK 不会丢**；
- 发布脚本会保留失败状态（CI 标红），不要误以为"重跑就好"——按下面的本地补发路径收口。

### 本地补发步骤

```bash
REPO=yuedaochangmendian/throne-flclash-ui
TAG=v3.2.18
SHA=<目标提交 sha>

# 1. 取回已构建并签名的产物
gh run download <失败或 publish=false 的 run id> \
    -n "Flrone-$TAG-publish-failed" -D dist/     # 或 -n "Flrone-$TAG"
ls -l dist/                                      # 应含 3 个 APK、SHA256SUMS、throne-update.json

# 2. 若发行版不存在，先创建草稿（本地 API 通道通常可用）
notes=$(bash buildScript/release_notes.sh "${TAG#v}")
jq -n --arg tag "$TAG" --arg sha "$SHA" --arg body "$notes" \
  '{tag_name:$tag, target_commitish:$sha, name:$tag, body:$body, draft:true, prerelease:false}' \
  | gh api -X POST "repos/$REPO/releases" --input - | tee release.json
REL_ID=$(jq -r .id release.json)

# 3. 上传资产（uploads.github.com，与 api.github.com 是不同端点）
for f in dist/*; do
  curl -fsS -X POST \
    -H "Authorization: Bearer $(gh auth token)" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$f" \
    "https://uploads.github.com/repos/$REPO/releases/$REL_ID/assets?name=$(basename "$f")" \
    > /dev/null && echo "uploaded $(basename "$f")"
done

# 4. 发布并核对
echo '{"draft":false}' | gh api -X PATCH "repos/$REPO/releases/$REL_ID" --input - > /dev/null
gh release view "$TAG" --json tagName,isDraft,targetCommitish,assets
```

### 两个坑

- **草稿是 untagged 形态**：`GET /releases/tags/<tag>` 对草稿返回 404，但草稿确实存在。始终按 release **id** 查询（`GET /releases/<id>`），不要因为 404 就重复创建。
- **发布前确认 `target_commitish`**：草稿创建时必须写目标提交 sha；否则 tag 可能落到默认分支的旧提交。发布后用 `gh api repos/$REPO/git/ref/tags/$TAG` 复核。

### 可选的清理

若补发时已有同名草稿（如本地创建过但没上传资产），优先复用它（`gh release upload <tag> dist/* --clobber` + `gh release edit <tag> --draft=false`），或先 `gh release delete <tag> --yes` 再走上面的流程。
