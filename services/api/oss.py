"""OSS 预签名(GET/PUT)。签名三件套 `_sign` / `canonical_resource` / `build_presigned`
逐字复制自 `services/claim-signer/handler.py`(2026-09-11),不改一个字符——两处的签名
必须永远一致,claim-signer 的 test_handler.py 里的已知向量同样适用于这里。"""
import base64
import hashlib
import hmac
import os
import time
import urllib.parse


def _sign(secret: str, string_to_sign: str) -> str:
    """OSS V1 签名:base64(HMAC-SHA1(AccessKeySecret, StringToSign))。"""
    mac = hmac.new(secret.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha1)
    return base64.b64encode(mac.digest()).decode("utf-8")


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


PRESIGN_TTL = 600
CONTENT_TYPE = "application/octet-stream"


def presign(verb: str, key: str, content_type: str = CONTENT_TYPE, ttl: int = PRESIGN_TTL) -> str:
    return build_presigned(
        verb=verb, access_key_id=os.environ["OSS_ACCESS_KEY_ID"].strip(), access_key_secret=os.environ["OSS_ACCESS_KEY_SECRET"].strip(),
        bucket=os.environ["OSS_BUCKET"].strip(), endpoint=os.environ["OSS_ENDPOINT"].strip(), key=key,
        expires_at=int(time.time()) + ttl, content_type=content_type if verb == "PUT" else "",
    )
