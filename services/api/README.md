# 账号 / 同步 API(services/api)

MedMe 账号、加密同步、授权、LLM 代理的后端骨架。本任务只落地认证:手机验证码
(阿里云 PNVS)、Sign in with Apple、JWT access/refresh、微信登录留 501。后续任务
(同步、授权、LLM 代理)往同一个 `app.py` / `db.py` / `auth.py` 追加路由和函数,不建
新文件。

服务端**只见密文**:病历明文、档案密钥、账号私钥、口令、恢复码永不上传;手机号只以
HMAC 哈希存储,验证码只以哈希存储并带次数上限与过期时间。这份代码里不该出现任何解密
调用——加了就是设计错了。

## 两种运行时都能跑

与 `services/claim-signer/` 一样只依赖标准库 + pip 包,不绑定平台:

- **自定义运行时**(阿里云 FC):`python3 -m uvicorn app:app --host 0.0.0.0 --port 9000`
- 本地 / VPS / 容器:同一条命令直接跑

## 部署(自定义运行时)

1. **创建函数** → Web 函数 → 运行环境**自定义运行时**
2. 启动命令 `python3 -m uvicorn app:app --host 0.0.0.0 --port 9000`,执行超时按接口调整
   (认证接口给 15 秒够了)
3. 打包:`pip install -r requirements.txt -t .` 后把 `services/api/` 整个目录传上去
4. **环境变量**(在函数配置里加,不要写进代码):

   | 变量 | 值 / 说明 |
   |---|---|
   | `DATABASE_URL` | `postgresql://user:pass@host:5432/dbname` |
   | `API_JWT_SECRET` | 签 access/refresh token 的 HMAC 密钥 |
   | `PHONE_HMAC_KEY` | 手机号哈希用的 HMAC 密钥(与 `API_JWT_SECRET` 不同key) |
   | `ALIYUN_ACCESS_KEY_ID` / `ALIYUN_ACCESS_KEY_SECRET` | 阿里云 RAM 用户,调 PNVS |
   | `PNVS_SIGN_NAME` | 短信签名 |
   | `PNVS_TEMPLATE_CODE` | 短信模板 code |
   | `APPLE_BUNDLE_ID` | `com.medme.mobile` |
   | `OSS_BUCKET` | `medme-vault`(后续同步任务用) |
   | `OSS_ENDPOINT` | 如 `oss-cn-hangzhou.aliyuncs.com` |
   | `DEEPSEEK_API_KEY` | 后续 LLM 代理任务用 |
   | `MEDME_EXTRACT_TOKEN` | 可选,子项目 A 评测期的静态 token,与 claim-signer 的 `MEDME_UPLOAD_TOKEN` 同一模式 |
   | `OTP_DRY_RUN` | 可选,测试/联调用,设了就不真发短信、验证码固定 `000000` —— **绝不能在生产设置** |

5. **触发器**:HTTP,认证方式按需(登录接口要能被 App 匿名调用)

RDS 用 Serverless PG(杭州),记得开 **RDS Proxy**,否则 FC 每次冷启动都新开一条连接,
并发上来会打满 Postgres 的连接数。

## 建表

`db.ensure_schema(conn)` 在 `app.py` 的 startup 钩子里自动跑,全用
`CREATE TABLE IF NOT EXISTS`,可重复执行、不需要单独的迁移步骤。

## 验证

```bash
# 建一次本地测试库(与 mimiciv_omop 的 5435 实例共用,互不影响)
createdb -h localhost -p 5435 -U postgres medme_api_test

cd services/api
pip install -r requirements.txt -q
DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest -q
# 期望:3 passed
```

测试不打真实的阿里云 / Apple 网络请求:`OTP_DRY_RUN=1` 让验证码固定为 `000000`;
Apple 分支测的是格式错误的 `identity_token`,在 `jwt.get_unverified_header` 那步就
失败,不会走到拉 JWKS 那步。

## 已知缺口

- **微信登录只留位。** `WeChatProvider.login` 直接 `raise NotImplementedError`,路由
  返回 501。要接的话:营业执照 + 微信开放平台认证之后,在这里接 `code2session`,账号表
  已经留了 `wechat_openid` 列。
- **`MEDME_EXTRACT_TOKEN` 挡不住反编译**(与 claim-signer 的 `MEDME_UPLOAD_TOKEN` 同一
  局限),只用于子项目 A 的评测期,不是长期认证方案。
- **OTP 限频是单实例内存无关的、纯 DB 计数**,没有额外的 IP 限流;真上量后应该在 FC
  前面加流控。
