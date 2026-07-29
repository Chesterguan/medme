"""瞬时云的上传签名端点(阿里云函数计算 FC 3.0,Python HTTP 函数)。

**为什么需要它。** 桶是「公共读 + 私有写」:任何人都能凭对象 id 读回那坨密文(读不懂,
密钥从不上云),但**写必须签名**。而签名要 AccessKey,AccessKey 绝不能进手机 App ——
谁都能反编译扒出来,然后往桶里塞任意内容,而账号是实名主体的。

所以手机不直接持钥,而是:

    手机 → 本函数「我要传一份」→ 拿到一个限时的预签名 PUT 地址 → 直接 PUT 上 OSS

对象名由**本函数**生成,客户端不能指定 —— 否则可以覆盖别人的对象,或造出一个好记的
公开 URL。

**已知缺口(必须知道):** OSS V1 预签名 URL **无法限制上传体积**。拿到地址的人可以传
一个很大的文件。缓解手段:地址只活 10 分钟、对象名不可预测、桶上有 15 天生命周期规则
兜底。要真正限体积得改用 POST Policy(表单上传,可设 content-length-range),客户端要
改成 multipart,代价更大 —— 内测阶段先不做,但**上真实流量前应该做**。

环境变量(在 FC 控制台配置,**不要写进代码**):
    OSS_ACCESS_KEY_ID       RAM 用户的 AccessKey ID
    OSS_ACCESS_KEY_SECRET   RAM 用户的 AccessKey Secret
    OSS_BUCKET              medme-claim
    OSS_ENDPOINT            oss-cn-hangzhou.aliyuncs.com
    MEDME_UPLOAD_TOKEN      (可选)共享口令;设了就要求请求头带 X-MedMe-Token
"""

import base64
import hashlib
import hmac
import json
import os
import secrets
import time
import urllib.parse

# 预签名地址的有效期。够手机传完一份几十 MB 的密文,又短到捡到也没什么用。
PRESIGN_TTL_SECONDS = 600

# 对象前缀必须与桶上的生命周期规则一致(`c/` → 15 天后删除)。改这里就要改那条规则,
# 否则对象会永远留着 —— 那就违背了「云是中转,不是存储」。
KEY_PREFIX = "c/"

# 客户端 PUT 时必须原样带上这个 Content-Type:它进签名串,对不上 OSS 会拒。
CONTENT_TYPE = "application/octet-stream"


def _sign(secret: str, string_to_sign: str) -> str:
    """OSS V1 签名:base64(HMAC-SHA1(AccessKeySecret, StringToSign))。"""
    mac = hmac.new(secret.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha1)
    return base64.b64encode(mac.digest()).decode("utf-8")


def build_presigned_put(
    *,
    access_key_id: str,
    access_key_secret: str,
    bucket: str,
    endpoint: str,
    key: str,
    expires_at: int,
    content_type: str = CONTENT_TYPE,
) -> str:
    """产出一个限时的 PUT 地址。

    StringToSign 的结构由 OSS 规定,顺序与换行都不能动:

        VERB \n Content-MD5 \n Content-Type \n Expires \n CanonicalizedOSSHeaders + CanonicalizedResource

    我们不带 Content-MD5、不带任何 `x-oss-` 头,所以那两段为空(但换行必须保留)。
    CanonicalizedResource 是 `/<bucket>/<key>`,**不做 URL 编码**。
    """
    string_to_sign = "\n".join(
        [
            "PUT",
            "",  # Content-MD5:不带
            content_type,
            str(expires_at),
            f"/{bucket}/{key}",  # CanonicalizedOSSHeaders 为空,直接接 Resource
        ]
    )
    signature = _sign(access_key_secret, string_to_sign)
    query = urllib.parse.urlencode(
        {
            "OSSAccessKeyId": access_key_id,
            "Expires": str(expires_at),
            "Signature": signature,
        }
    )
    # key 里只有 [A-Za-z0-9_-] 和一个 `/`,quote 时把 `/` 保留成路径分隔符。
    return f"https://{bucket}.{endpoint}/{urllib.parse.quote(key, safe='/')}?{query}"


def new_object_key() -> str:
    """对象名:96 位随机,不可枚举。**由服务端生成,客户端无权指定。**"""
    return KEY_PREFIX + secrets.token_urlsafe(12)


def _json_response(start_response, status: str, payload: dict):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    start_response(
        status,
        [("Content-Type", "application/json; charset=utf-8"), ("Content-Length", str(len(body)))],
    )
    return [body]


def handler(environ, start_response):
    """FC 3.0 Python HTTP 函数入口(WSGI)。"""
    ak = os.environ.get("OSS_ACCESS_KEY_ID", "")
    sk = os.environ.get("OSS_ACCESS_KEY_SECRET", "")
    bucket = os.environ.get("OSS_BUCKET", "")
    endpoint = os.environ.get("OSS_ENDPOINT", "")
    if not (ak and sk and bucket and endpoint):
        # 配置缺失是部署问题,不是调用方的问题 —— 明确报 500,别伪装成签名失败。
        return _json_response(
            start_response, "500 Internal Server Error", {"error": "server_not_configured"}
        )

    # 可选的共享口令。它挡不住反编译(口令也在 App 里),但能挡住扫互联网的脚本 ——
    # 把「谁都能拿到上传地址」抬高到「得先拆包」。
    expected_token = os.environ.get("MEDME_UPLOAD_TOKEN", "")
    if expected_token:
        got = environ.get("HTTP_X_MEDME_TOKEN", "")
        # 定长比较,别让响应时间泄漏口令前缀。
        if not hmac.compare_digest(got, expected_token):
            return _json_response(start_response, "403 Forbidden", {"error": "forbidden"})

    key = new_object_key()
    expires_at = int(time.time()) + PRESIGN_TTL_SECONDS
    url = build_presigned_put(
        access_key_id=ak,
        access_key_secret=sk,
        bucket=bucket,
        endpoint=endpoint,
        key=key,
        expires_at=expires_at,
    )
    return _json_response(
        start_response,
        "200 OK",
        {
            # 客户端把这个 id 放进二维码 / 认领链接;它已含 `c/` 前缀之后的部分。
            "id": key[len(KEY_PREFIX) :],
            "uploadUrl": url,
            "contentType": CONTENT_TYPE,
            "expiresIn": PRESIGN_TTL_SECONDS,
        },
    )
