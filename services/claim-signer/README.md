# 上传签名端点(claim-signer)

瞬时云的「发上传许可证」的地方。手机不持 AccessKey,而是问它要一个**限时的预签名 PUT
地址**,再直接把密文 PUT 上 OSS。

```
手机 ──「我要传一份」──▶ claim-signer ──签名──▶ 返回 {id, uploadUrl}
  └──────────── PUT 密文 ────────────▶ OSS(medme-claim)
```

## 为什么不能省掉它

桶是**公共读 + 私有写**。写要签名,签名要 AccessKey,而 AccessKey **绝不能进 App** ——
谁都能反编译扒出来往桶里塞东西,而账号是实名主体的。阿里云官方对客户端直传的结论也是
这个:必须有一个服务端签发凭证。

## 两种运行时都支持

| 文件 | 用于 |
|---|---|
| `handler.py` | 签名逻辑本体(两种运行时共用),兼作**托管 Python 运行时**的 WSGI 入口 `handler(environ, start_response)` |
| `app.py` | **自定义运行时**用的独立 HTTP Server(`python3 app.py`,监听 `PORT`,默认 9000) |

新版 FC 控制台的 Web 函数默认给「自定义运行时」,那就用 `app.py`(两个文件都要传,
`app.py` 会 import `handler.py`)。它只用标准库,不依赖任何平台 —— 搬到 VPS 或容器同样能跑。

## 部署(自定义运行时)

1. **创建函数** → Web 函数 → 运行环境**自定义运行时**
2. 启动命令 `python3 app.py`,监听端口 `9000`,执行超时 60 秒
3. 代码里放 `app.py` + `handler.py` 两个文件
3. **环境变量**(在函数配置里加,不要写进代码):

   | 变量 | 值 |
   |---|---|
   | `OSS_ACCESS_KEY_ID` | RAM 用户的 AccessKey ID |
   | `OSS_ACCESS_KEY_SECRET` | RAM 用户的 AccessKey Secret |
   | `OSS_BUCKET` | `medme-claim` |
   | `OSS_ENDPOINT` | `oss-cn-hangzhou.aliyuncs.com` |
   | `MEDME_UPLOAD_TOKEN` | (可选)共享口令,设了就要求请求头带 `X-MedMe-Token` |

4. **触发器**:HTTP,认证方式**匿名**(App 要能直接调),方法允许 `GET` + `POST`
5. 记下公网调用地址,填进 `apps/mobile_flutter/lib/claim_storage.dart` 的 `signerUrl`

RAM 用户的权限给 `AliyunOSSFullAccess` 即可(实际只用到 PutObject)。

## 验证

```bash
# 本地自检(无依赖,不需要凭证)
python3 services/claim-signer/test_handler.py

# 部署后:要到一个上传地址
curl -sS <函数地址> | python3 -m json.tool

# 拿着返回的 uploadUrl 真传一份(Content-Type 必须一致,否则签名对不上)
echo hello | curl -sS -X PUT --data-binary @- \
  -H 'Content-Type: application/octet-stream' \
  -o /dev/null -w '%{http_code}\n' '<uploadUrl>'
# 期望 200

# 再匿名读回来(桶是公共读)
curl -sS https://medme-claim.oss-cn-hangzhou.aliyuncs.com/c/<返回的 id>
# 期望输出 hello
```

## 已知缺口

- **无法限制上传体积。** OSS V1 预签名 URL 签不进 Content-Length,拿到地址的人可以传一个
  很大的文件。缓解:地址只活 10 分钟、对象名不可预测、桶上 15 天生命周期兜底。要真正限
  体积得改用 **POST Policy**(可设 `content-length-range`),客户端要改成 multipart ——
  **上真实流量前应该做。**
- **用的是 V1 签名,阿里云现在推荐 V4。** V1 仍可用,但属于旧版。选它是因为实现短、
  出问题好定位;等链路稳定后值得升到 V4。
- **共享口令挡不住反编译**(口令也在 App 里),它只把「扫互联网就能拿到上传地址」抬高到
  「得先拆包」。真正的限流要靠 FC 的流量控制或在函数里加计数。
