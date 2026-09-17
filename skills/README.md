# skills/ — 病种包(公开静态资源,不含任何用户数据)

`<id>/<version>.src.json` 是人写的包;`<id>/<version>.json` 是 `scripts/sign_skill.py`
签出来的信封,**它才是 `GET /v1/skills/{id}/{ver}.json` 实际返回的字节**。两份都进仓库。

改包内容的唯一流程:改 `.src.json` → `python3 scripts/sign_skill.py <那个文件>` →
`cargo test -p profile --test repo_packages_verify` 必须绿 → commit 两份 + index.json。

私钥在发布者本机 `~/.medme_skill_signing_key`,不在仓库、不在 CI。
App 里编死的是公钥(`packages/profile/src/package.rs::SIGNING_PUBLIC_KEY_HEX`)。

> `index.json` 本任务里还没有签名(裸 JSON,由 `refresh_index()` 生成)。
> Task 27 把它换成与包同一种签名信封。
