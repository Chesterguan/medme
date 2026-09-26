# 阿里云配置(后端)—— 现状与操作手册

> 以此文件为准;改了资源就改这里。**任何密钥都不写进来**(AK 在 `~/.aliyun/config.json` 的 `medme` profile;数据库密码只在函数环境变量;DeepSeek key 在仓库根 `.deepseek_key`,不入库)。
> 最后核对:2026-09-21(每项都是用 CLI 实查过的);§1/§6 的短信部分 2026-09-25 按号码认证服务文档改正(之前误写成要去短信服务申请签名)。

## 1. 账号与权限

| 项 | 值 |
|---|---|
| 主账号 UID | 1476885253922647(管理员持有,**不要给任何人/代理**) |
| RAM 用户 | `medme`(CLI profile 同名;另有 `medme-admin` profile,同一把 key) |
| 地域 | `cn-hangzhou`(所有资源) |
| 现挂策略 | `AdministratorAccess`(2026-09-20 临时给的,**跑通后撤**)+ `AliyunVPCFullAccess` `AliyunECSFullAccess` `AliyunRDSFullAccess` `AliyunOSSFullAccess` `AliyunFCFullAccess` `AliyunDypnsFullAccess` |
| 日常运维最小集 | 上面 6 个 FullAccess(短信认证的发送/查询都在 `dypns` 下,**不需要** `AliyunDysmsFullAccess`) |
| 已创建的服务关联角色 | `AliyunServiceRoleForRdsPgsqlOnEcs`(RDS PG 必需;用 `aliyun rds CreateServiceLinkedRole --ServiceLinkedRole AliyunServiceRoleForRdsPgsqlOnEcs --RegionId cn-hangzhou --force` 建,**不是** `ram CreateServiceLinkedRole`) |

CLI:`aliyun configure list` 看 profile;`aliyun configure get` **打码输出 AK**,脚本要从 `~/.aliyun/config.json` 读(`services/api/deploy/creds.py`)。

## 2. 网络

| 资源 | ID | 备注 |
|---|---|---|
| VPC `medme-vpc` | `vpc-bp19034pe43gz6pxawixm` | 10.0.0.0/16 |
| vSwitch `medme-vsw-j` | `vsw-bp1bjdnil2nrk705a0lcl` | cn-hangzhou-j,10.0.1.0/24;FC 与 RDS 都在这一段 |
| 安全组 `medme-sg` | `sg-bp1d1d4t03k1rpcn3ucz` | 入站放行 tcp/5432 来源 10.0.0.0/16;FC 挂的就是它 |

## 3. 数据库(RDS PostgreSQL)

| 项 | 值 |
|---|---|
| 实例 | `pgm-bp1o4l88va6pz8j3`(描述 `medme-pg`) |
| 规格 | PostgreSQL 16.0,基础版,`pg.n2e.1c.1m`,20 GB `cloud_essd`,按量付费,cn-hangzhou-j |
| 内网地址 | `pgm-bp1o4l88va6pz8j3.pg.rds.aliyuncs.com:5432`(**没有公网地址**;白名单 10.0.0.0/16) |
| 库 / 账号 | `medme` / `medme_app`(高权限账号 + 对 `medme` 库 `DBOwner`——PG 15+ 的 `public` schema 没这一步建不了表) |
| 建表 | API 启动时 `CREATE TABLE IF NOT EXISTS`(`services/api/db.py`),不用手工迁移;**加列**要另写 ALTER(见 db.py 注释) |
| 连接串 | `postgresql://medme_app:<密码>@<内网地址>:5432/medme?sslmode=prefer`,只放函数环境变量 `DATABASE_URL` |

## 4. 对象存储(OSS,cn-hangzhou)

| 桶 | 用途 | 说明 |
|---|---|---|
| `medme-vault` | 账号云端备份的密文 | 2026-09-18 建;API 用 AK 签 URL |
| `medme-claim` | 医生代拍的认领包(瞬时云,15 天到期) | 2026-07-28 建;`claim-signer` 函数签 URL |
| `medme-deploy` | 部署包(`medme-api.zip`) | 私有;**已开传输加速**——本机直传杭州只有 ~12 KB/s,加速端点 `medme-deploy.oss-accelerate.aliyuncs.com` 3.7 MB/s |

## 5. 函数计算(FC 3.0)

| 函数 | 运行时 | 配置 | 网络 | 入口 |
|---|---|---|---|---|
| `medme-api` | `custom.debian11`(Python 3.9.2 x86_64) | 1024 MB / 0.5 vCPU / 512 MB 盘 / 超时 150 s / 单实例并发 10 | 挂 VPC(上表三项);`role` 留空即可 | HTTP 触发器 `http`,匿名,GET/POST/PUT/DELETE → **`https://medme-api-sphuddkjsn.cn-hangzhou.fcapp.run`** |
| `claim-signer` | `custom.debian10` | 512 MB | 无 VPC | 代拍认领链接签名(见 memory `cloud-relay-live`) |
| `e2b-sandbox-template-*` ×4 | custom-container | 2048 MB | — | **不是 MedMe 的**,别动 |

`medme-api` 启动命令 `python3 -m uvicorn app:app --host 0.0.0.0 --port 9000`,代码来自 OSS `medme-deploy/medme-api.zip`(包根 = `services/api/*.py` + 依赖 wheel + `skills/` + `prompts/`)。

环境变量(值不写这里):`DATABASE_URL` `API_JWT_SECRET` `PHONE_HMAC_KEY` `ALIYUN_ACCESS_KEY_ID/SECRET` `PNVS_SIGN_NAME` `PNVS_TEMPLATE_CODE`(**目前为空,短信发不出**)`APPLE_BUNDLE_ID=com.medme.mobile` `OSS_ACCESS_KEY_ID/SECRET` `OSS_BUCKET=medme-vault` `OSS_ENDPOINT=oss-cn-hangzhou.aliyuncs.com` `DEEPSEEK_API_KEY` `DEEPSEEK_MODEL_TEXT/VISION`(现 `deepseek-flash`,模型名不绑死)`MEDME_SKILLS_DIR=/code/skills` `MEDME_PROMPTS_DIR=/code/prompts` `PYTHONPATH=/code`。

`API_JWT_SECRET` / `PHONE_HMAC_KEY` / `DATABASE_URL`:`deploy_api.sh` 在函数已存在时**沿用线上函数环境变量里的值**(env.sh 不必、也不该再抄一份密钥);只有首次创建才随机生成。env.sh 只放 VPC/vSwitch/安全组 ID 和 `PNVS_*`。

## 6. 短信(号码认证服务 · 短信认证,免资质)

登录验证码走 PNVS `SendSmsVerifyCode`(`services/api/auth.py`),用的是**号码认证服务里的「短信认证」**,不是短信服务:个人实名账号即可,**不用营业执照、不用申请签名和模板、没有审核**——平台赠送签名和 5 个验证码模板,而且赠送签名只能配赠送模板,不支持自定义(文档:`help.aliyun.com/zh/pnvs/use-cases/sms-verify-for-individual-developers`)。只发大陆 +86 号码,按条计费、失败不计费。

开通与取值(控制台,主账号或有 `AliyunDypnsFullAccess` 的账号):
1. `dypns.console.aliyun.com/functions` → 「短信认证」开通(没开时 API 报 `FUNCTION_NOT_OPENED`)。
2. 短信认证 → 参数配置 → 签名配置 → **赠送签名配置**:任选一个,签名名称原样抄给 `PNVS_SIGN_NAME`。
3. 同处 → 模板配置 → **赠送模板配置**:「登录/注册」模板编号 `100001` → `PNVS_TEMPLATE_CODE`。模板变量是 `code`(验证码)和 `min`(有效期分钟),`auth.py` 两个都传;验证码是我们自己生成、自己在 `otp` 表里校验的,不用 `CheckSmsVerifyCode`。
4. 填进 `deploy/env.sh` 后 `bash deploy/deploy_api.sh` 重部署(密钥自动沿用线上的,见 §5)。
5. 想先在控制台试发:短信认证 → 测试,只能发给已绑定的测试号(每账号 5 个),试发也计费。

## 7. 手机端怎么指向后端

CI(`.github/workflows/mobile.yml`)读仓库变量 `MEDME_API_BASE`(已设为上面的 fcapp.run 地址)传 `--dart-define`。本地运行:`--dart-define=MEDME_API_BASE=...`;本机调试用 `services/api` 直接 `uvicorn`(`OTP_DRY_RUN` 只许本机)。

## 8. 操作手册(脚本在 `services/api/deploy/`)

1. 打包:`bash services/api/deploy/build_api_pkg.sh` → `deploy/medme-api.zip`(pip 按 manylinux2014/cp39 拉 wheel)。
2. 上传:`export ALIYUN_ACCESS_KEY_ID=$(python3 deploy/creds.py medme id) ALIYUN_ACCESS_KEY_SECRET=$(python3 deploy/creds.py medme secret); /usr/bin/python3 deploy/mpu.py deploy/medme-api.zip`(分片 + 加速端点,可断点续传;用系统 python,python.org 的 3.9 缺 CA 证书)。
3. 部署/更新函数:`cp deploy/env.example.sh deploy/env.sh` 填好 → `bash deploy/deploy_api.sh`(存在则 PUT 更新并沿用线上密钥,不存在则 POST 创建 + 建触发器)。
4. 首次建库全套:`bash deploy/finish_backend.sh`(幂等:建实例 → 等 Running → 账号/库/DBOwner → 写 env.sh → 部署 → curl)。
5. 验证:`curl https://medme-api-sphuddkjsn.cn-hangzhou.fcapp.run/v1/skills/index.json` 应 200;启动失败时 412 响应体里带完整 traceback(`Message` 字段,去掉 ANSI 色码看)。

## 9. 踩过的坑

- 后台长命令会被本机低内存杀掉(Teams 吃 1 GB);上传用分片脚本前台跑。
- `--body` 传 38 MB base64 会 `Argument list too long`;代码一律走 OSS 引用。
- 函数包里没有仓库树:`skills/`、`prompts/` 要打进包并用 `MEDME_*_DIR` 指路(否则 `FileNotFoundError` 启动即崩)。
- `aliyun rds CreateDatabase` 参数是 `--CharacterSetName`;`DescribeAvailableZones` 对 PG16 返回空,规格直接用 `pg.n2e.1c.1m`/cn-hangzhou-j 即可。
- 安全组是 ECS 的 API(`AliyunECSFullAccess`),VPC 权限不含它。

## 10. 费用(按量)

RDS 基础版 1c1m + 20 GB ESSD、FC 按调用与运行时长、OSS 三桶存储 + 流量、传输加速按流量。内测阶段都很小;上线前再评估是否换包年。
