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

# 注:刻意不用 `dict | None` 这类 3.10+ 语法 —— 本地自检可能在更老的 Python 上跑,
# 而这份代码要能在本机直接 `python3 test_handler.py` 验证,不该被运行时版本挡住。

# 预签名地址的有效期。够手机传完一份几十 MB 的密文,又短到捡到也没什么用。
PRESIGN_TTL_SECONDS = 600

# 对象前缀必须与桶上的生命周期规则一致(`c/` → 15 天后删除;**规则已在阿里云控制台
# 确认存在**,2026-07-29)。改这里就要改那条规则,
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


# 分片大小的硬约束(OSS):除最后一片外每片 ≥100KB,片号 1–10000。
MIN_PART_SIZE = 256 * 1024
MAX_PART_SIZE = 5 * 1024 * 1024
MAX_PARTS = 10000

# 目标片数。官方提醒:「文件小于 100MB 时若 partSize 设置不合理,可能无法完整显示上传
# 进度」—— 固定 1MB 的话 5MB 载荷只有 6 片,进度一跳一跳。按份数目标反算大小,让进度
# 平滑;顺带好处是**断一次少重传**(片越小,白费的越少)。
TARGET_PARTS = 20


def part_size_for(size):
    """按总大小反算分片大小,夹在 OSS 的合法区间内。

    我们用分片**不是因为文件大**(官方建议 >100MB 才用),而是因为要**断了能续**。
    所以 5MB 也切片 —— 目标是每次断网只损失一小片,而不是整份重来。
    """
    want = max(MIN_PART_SIZE, -(-size // TARGET_PARTS))
    want = min(want, MAX_PART_SIZE)
    if -(-size // want) > MAX_PARTS:  # 极端大文件:别让片数超上限
        want = -(-size // MAX_PARTS)
    return want

# 分片上传整体的有效期。简单 PUT 给 10 分钟够了,但分片要覆盖「传到一半断网、过几分钟
# 恢复接着传」,所以放宽到 2 小时。它只是签名的有效期,不是对象的保留期。
MULTIPART_TTL_SECONDS = 2 * 60 * 60


def canonical_resource(bucket, key, subresources=None):
    """CanonicalizedResource:`/bucket/key` + 排序后的子资源。

    **子资源必须按字典序升序**,以 `&` 分隔,接在 `?` 之后(见 OSS 签名文档)。
    顺序错了签名就对不上,而 OSS 只会回 SignatureDoesNotMatch,不告诉你错在哪。
    值为 None 的子资源只出现键(如 `?uploads`),有值的写成 `键=值`。
    """
    res = f"/{bucket}/{key}"
    if subresources:
        parts = []
        for k in sorted(subresources):
            v = subresources[k]
            parts.append(k if v is None else f"{k}={v}")
        res += "?" + "&".join(parts)
    return res


def build_presigned(
    *,
    verb: str,
    access_key_id: str,
    access_key_secret: str,
    bucket: str,
    endpoint: str,
    key: str,
    expires_at: int,
    content_type: str = "",
    subresources=None,
) -> str:
    """通用的预签名 URL 构造(简单 PUT / 分片各步都走这里,只有一处签名实现)。"""
    string_to_sign = "\n".join(
        [verb, "", content_type, str(expires_at), canonical_resource(bucket, key, subresources)]
    )
    query = {
        "OSSAccessKeyId": access_key_id,
        "Expires": str(expires_at),
        "Signature": _sign(access_key_secret, string_to_sign),
    }
    # 子资源既要进签名串,也要真的出现在 URL 上。
    if subresources:
        for k in sorted(subresources):
            query[k] = "" if subresources[k] is None else subresources[k]
    # urlencode 会把无值子资源写成 `uploads=`;OSS 接受这种形式。
    return f"https://{bucket}.{endpoint}/{urllib.parse.quote(key, safe='/')}?{urllib.parse.urlencode(query)}"


def new_object_key() -> str:
    """对象名:96 位随机,不可枚举。**由服务端生成,客户端无权指定。**"""
    return KEY_PREFIX + secrets.token_urlsafe(12)


def initiate_multipart(*, access_key_id, access_key_secret, bucket, endpoint, key, size):
    """发起分片上传并把各步的预签名地址一次性备齐。

    为什么由**服务端**发起:分片的每一步签名都要 uploadId,而 uploadId 只有发起之后才
    存在。让客户端先来要一次「发起地址」、传完再来要「各片地址」,等于多一轮往返,而且
    断网重连时还要重新协商。服务端一次做完,客户端拿到就能一路传下去。

    返回结构里 `parts` 是**有序**的;客户端按序传,收集每片的 ETag,最后把它们拼成 XML
    发给 `completeUrl`。中途断了,已成功的片不必重传 —— 这正是断点续传的基础。
    """
    import xml.etree.ElementTree as ET
    from urllib.request import Request, urlopen

    expires_at = int(time.time()) + MULTIPART_TTL_SECONDS

    # ① 发起:POST /key?uploads。这一步服务端自己做,因为要拿 uploadId。
    init_url = build_presigned(
        verb="POST", access_key_id=access_key_id, access_key_secret=access_key_secret,
        bucket=bucket, endpoint=endpoint, key=key, expires_at=expires_at,
        content_type=CONTENT_TYPE, subresources={"uploads": None},
    )
    req = Request(init_url, data=b"", method="POST",
                  headers={"Content-Type": CONTENT_TYPE, "Content-Length": "0"})
    body = urlopen(req, timeout=20).read()
    upload_id = ET.fromstring(body).findtext("UploadId")
    if not upload_id:
        raise RuntimeError("OSS 未返回 UploadId")

    # ② 各片:PUT /key?partNumber=N&uploadId=X。片号从 1 开始。
    part_size = part_size_for(size)
    n_parts = max(1, -(-size // part_size))  # 向上取整
    parts = [
        {
            "partNumber": i,
            "url": build_presigned(
                verb="PUT", access_key_id=access_key_id, access_key_secret=access_key_secret,
                bucket=bucket, endpoint=endpoint, key=key, expires_at=expires_at,
                content_type=CONTENT_TYPE,
                subresources={"partNumber": str(i), "uploadId": upload_id},
            ),
        }
        for i in range(1, n_parts + 1)
    ]

    # ③ 合并 / ④ 放弃。合并的请求体是 XML,Content-Type 必须与签名里一致。
    complete_url = build_presigned(
        verb="POST", access_key_id=access_key_id, access_key_secret=access_key_secret,
        bucket=bucket, endpoint=endpoint, key=key, expires_at=expires_at,
        content_type="application/xml", subresources={"uploadId": upload_id},
    )
    abort_url = build_presigned(
        verb="DELETE", access_key_id=access_key_id, access_key_secret=access_key_secret,
        bucket=bucket, endpoint=endpoint, key=key, expires_at=expires_at,
        subresources={"uploadId": upload_id},
    )
    return {
        "id": key[len(KEY_PREFIX):],
        "uploadId": upload_id,
        "partSize": part_size,
        "parts": parts,
        "completeUrl": complete_url,
        "abortUrl": abort_url,
        "contentType": CONTENT_TYPE,
        "completeContentType": "application/xml",
        "expiresIn": MULTIPART_TTL_SECONDS,
    }


def _json_response(start_response, status: str, payload: dict):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    start_response(
        status,
        [("Content-Type", "application/json; charset=utf-8"), ("Content-Length", str(len(body)))],
    )
    return [body]


def handler(environ, start_response):
    """FC 3.0 Python HTTP 函数入口(WSGI)。"""
    ak = os.environ.get("OSS_ACCESS_KEY_ID", "").strip()
    sk = os.environ.get("OSS_ACCESS_KEY_SECRET", "").strip()
    bucket = os.environ.get("OSS_BUCKET", "").strip()
    endpoint = os.environ.get("OSS_ENDPOINT", "").strip()
    if not (ak and sk and bucket and endpoint):
        # 配置缺失是部署问题,不是调用方的问题 —— 明确报 500,别伪装成签名失败。
        return _json_response(
            start_response, "500 Internal Server Error", {"error": "server_not_configured"}
        )

    # 可选的共享口令。它挡不住反编译(口令也在 App 里),但能挡住扫互联网的脚本 ——
    # 把「谁都能拿到上传地址」抬高到「得先拆包」。
    expected_token = os.environ.get("MEDME_UPLOAD_TOKEN", "").strip()
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
