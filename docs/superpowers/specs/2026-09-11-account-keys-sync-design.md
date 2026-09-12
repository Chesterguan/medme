# 子项目 B · 账号 + 密钥 + 加密同步 + 授权 + LLM 代理(2026-09-11)

> 总纲见 `2026-09-11-advanced-edition-overview-design.md`。本文只写 B。

## 目标

给保险箱一个身份,让它能换机、能授权给家属/医生、能为云抽取计费;**服务器永远只见密文**。
不登录 = 现在的纯本地行为,一切照旧(现有测试用户不被打断)。

## 1. 后端

- 运行时:沿用阿里云 FC 自定义运行时 + Python(`services/claim-signer/` 的部署方式已验证)。新服务 `services/api/`,FastAPI,一个函数。
- 数据库:阿里云 RDS PostgreSQL Serverless(杭州,与桶同地域)。
- 对象存储:现有 OSS,新桶 `medme-vault`(**私有读写**,与 `medme-claim` 公共读的语义不同,不混用)。
- 短信:阿里云号码认证服务 PNVS「短信认证」(个人实名可用,赠送签名+模板,仅 +86)。

### 表

| 表 | 字段(要点) |
|---|---|
| accounts | id, phone_hash, apple_sub?, wechat_openid?(预留), public_key, wrapped_priv_pw, wrapped_priv_rc, kdf_params, created_at |
| devices | account_id, device_id, name, last_seen |
| profiles | id, owner_account_id, created_at |
| grants | profile_id, grantee_kind(account\|org), grantee_id, role(owner\|editor\|viewer), expires_at?, wrapped_profile_key, created_by, created_at |
| events | profile_id, event_id, ciphertext, device_id, ts, seq |
| objects | profile_id, object_id, size, created_at(字节在 OSS `v/<profile_id>/<object_id>`) |
| usage | account_id, month, llm_tokens_in/out, storage_bytes |
| otp | phone_hash, code_hash, expires_at, attempts |

主人也是一条 grant(role=owner)。**一套机制管主人、家属、医生、机构。**

### 接口(v1)

| 路径 | 作用 |
|---|---|
| `POST /v1/auth/otp` `POST /v1/auth/login` | 手机验证码;返回 access/refresh token |
| `POST /v1/auth/apple` | Apple 登录;`/v1/auth/wechat` **只留路由与 `LoginProvider` 接口,返回 501** |
| `PUT /v1/account/keys` `GET /v1/account/keys` | 上传/取回公钥与两份包好的私钥 |
| `POST /v1/profiles` | 建档案(同时写 owner grant) |
| `POST /v1/profiles/{id}/grants` `DELETE …/grants/{gid}` | 授权 / 撤销 |
| `POST /v1/profiles/{id}/transfer` | 所有权转移(新 owner grant + 旧 owner 降为 editor) |
| `GET /v1/profiles/{id}/events?since=` `POST …/events` | 事件拉/推(服务端按 role 拒写) |
| `POST /v1/profiles/{id}/objects/sign` | 预签名 PUT/GET(沿用 claim-signer 的签名代码) |
| `POST /v1/extract` | LLM 代理(见子项目 A §2),计入 usage |
| `POST /v1/devices/approve` | 旧设备给新设备包一份私钥(换机无口令路径) |

## 2. 密钥体系(客户端 Rust,新 crate `packages/sync`)

| 密钥 | 生成 | 保护 |
|---|---|---|
| 账号密钥对(X25519) | 注册时本机生成 | 私钥用 KEK 包(AES-256-GCM);KEK = Argon2id(口令) |
| 恢复码 | 注册时本机生成,20 位 base32 分组显示(`X7KQ-2M9P-…`) | 派生第二个 KEK,私钥再包一份 |
| 档案密钥(32 B) | 建档案时随机 | 用每个被授权账号的公钥封(sealed box),存 grants.wrapped_profile_key |
| 对象/事件密文 | AES-256-GCM(`aes-gcm` 已是依赖),随机 12 B nonce,AAD = object_id / event_id | |
| object_id | `HMAC-SHA256(profile_key, sha256(plaintext))`(`hmac` 已是依赖) | 服务端拿不到明文哈希 |
| 日期偏移秘密 | = 档案密钥(子项目 A 的 `profile_secret` 在此接上) | |

换机三条路,按无摩擦到有摩擦:旧设备批准(`/devices/approve`)→ 系统钥匙串(iOS Keychain 同步;安卓按厂商,先不做)→ 口令 → 恢复码。**都丢 = 数据丢,不代管。**

## 3. 同步

- 真相 = 事件日志 + CAS,已是 append-only(`docs/011_Storage_Sync.md`)。每个事件单独加密上传;每台设备记水位;拉回后 `materialize`。并集 + 按 (ts, device_id, seq) 排序,免冲突。
- 对象按需拉(先拉事件,原件点开再取),后台预取最近 N 份。
- 上传前先压图(总纲横切 4)。

## 4. 授权语义

| 场景 | role | 有效期 | 发起 |
|---|---|---|---|
| 家属/朋友 | editor | 永久 | 主人在 app 里选联系人(手机号)或扫码 |
| 医生 | viewer | **15 天** | 患者出示二维码,医生扫码 |
| 机构 | viewer | 到期 | 预留 `grantee_kind=org`,v1 不开 |
| 代拍 | 医生建档案 → `transfer` 给患者(认领链接 = 转移) | 医生保留 viewer 15 天或不留 | |

医生端**没有「我的患者」管理页**,只有「最近打开」,过期自动消失。
撤销 v1 = 删 grant 行(服务端不再供数);**档案密钥轮换排 v2**,对外话术写「撤销后不再能获取新内容」。

## 5. 客户端接入(Flutter)

- 设置页加「账号」:登录 / 注册(口令 + 展示恢复码并要求确认已保存)/ 设备列表 / 授权列表。
- 档案切换器(`member_switcher`)改吃「我拥有 + 被授权给我」的档案列表;本机纯本地档案照旧。
- 医生模式:扫码 → 15 天 viewer → 直接在 app 里打开档案(不再收 HTML 文件);现有二维码/HTML 分享保留给未登录用户。
- 三态必验(加载中/成功/失败,memory `test-all-three-states`)。

## 6. 不做(v1)

- 不做密钥代管;不做微信/支付宝登录(接口留着);不做机构账号 UI;不做撤销时密钥轮换;不做安卓钥匙串同步;桌面端不接。

## 7. 风险

- Argon2 在老安卓机上的耗时 → 参数按 Mate 9 实测定。
- FC 冷启动 + RDS 连接 → 用 RDS 连接池代理(阿里云 RDS Proxy)或保持最小实例。
- 短信被刷 → otp 表限次 + 单号频率限制。
