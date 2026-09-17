# skills/ — 病种包(公开静态资源,不含任何用户数据)

`<id>/<version>.src.json` 是人写的包;`<id>/<version>.json` 是 `scripts/sign_skill.py`
签出来的信封,**它才是 `GET /v1/skills/{id}/{ver}.json` 实际返回的字节**。两份都进仓库。
`index.src.json` / `index.json` 是同一套关系:清单与包用**同一种签名信封**、同一把
私钥,由 `refresh_index()` 生成——不签的话中间人能把新版本从清单里删掉(把用户按在
旧规则上),或者改一行 `version` 去拼任意路径。

改包内容的唯一流程:改 `.src.json` → `python3 scripts/sign_skill.py <那个文件>` →
`cargo test -p profile --test repo_packages_verify` 必须绿 → commit 两份 + index.src.json
+ index.json。只删包、不改任何包内容时,用 `python3 scripts/sign_skill.py --reindex`
单独重签清单。

私钥在发布者本机 `~/.medme_skill_signing_key`,不在仓库、不在 CI。
App 里编死的是公钥(`packages/profile/src/package.rs::SIGNING_PUBLIC_KEY_HEX`)。
