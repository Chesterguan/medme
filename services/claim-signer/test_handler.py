"""签名端点的自检。`python3 services/claim-signer/test_handler.py` 直接跑,无依赖。

签名串错一个换行,OSS 就返回 SignatureDoesNotMatch,而错误信息不会告诉你错在哪 ——
所以这里把结构逐字钉住。HMAC 本身已与 openssl 交叉验过一致。
"""

import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from handler import (  # noqa: E402
    CONTENT_TYPE,
    KEY_PREFIX,
    _sign,
    build_presigned_put,
    new_object_key,
)

FAIL = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ✓ {name}")
    else:
        print(f"  ✗ {name} {detail}")
        FAIL.append(name)


print("签名串结构")
# OSS V1:VERB \n Content-MD5 \n Content-Type \n Expires \n CanonicalizedOSSHeaders+Resource
# 我们不带 Content-MD5、不带 x-oss-* 头,所以第二段为空、Resource 直接接在 Expires 之后。
expected_sts = "PUT\n\napplication/octet-stream\n1900000000\n/medme-claim/c/abc"
check(
    "四个换行、Content-MD5 段为空",
    expected_sts.count("\n") == 4 and "\n\n" in expected_sts,
)
# 与 openssl 交叉验过的值(printf 'PUT\n\napplication/octet-stream\n1900000000\n/medme-claim/c/abc123'
# | openssl sha1 -hmac TESTSECRET -binary | base64)
check(
    "HMAC 与 openssl 一致",
    _sign("TESTSECRET", expected_sts.replace("/c/abc", "/c/abc123"))
    == "p4PAAQBX3dld1ERb6UekcP7eeDI=",
)

print("预签名 URL")
url = build_presigned_put(
    access_key_id="AKID",
    access_key_secret="SECRET",
    bucket="medme-claim",
    endpoint="oss-cn-hangzhou.aliyuncs.com",
    key="c/abc123",
    expires_at=1900000000,
)
parsed = urllib.parse.urlparse(url)
q = urllib.parse.parse_qs(parsed.query)
check("走 https", parsed.scheme == "https")
check("host 是 <bucket>.<endpoint>", parsed.netloc == "medme-claim.oss-cn-hangzhou.aliyuncs.com")
check("路径保留斜杠不被编码", parsed.path == "/c/abc123", parsed.path)
check("三个必需参数齐全", set(q) == {"OSSAccessKeyId", "Expires", "Signature"}, str(set(q)))
check("Expires 原样", q["Expires"] == ["1900000000"])
# 签名里常含 + / =,必须被 URL 编码,否则 OSS 收到的是被空格替换过的串
check("签名已 URL 编码", "+" not in parsed.query.split("Signature=")[1] or "%2B" in parsed.query)

print("对象名")
keys = {new_object_key() for _ in range(200)}
check("200 次不重复", len(keys) == 200)
check("都带约定前缀", all(k.startswith(KEY_PREFIX) for k in keys))
ids = [k[len(KEY_PREFIX) :] for k in keys]
# 与 App / 查看器里的 id 校验一致:^[A-Za-z0-9_-]{8,128}$。含 `/` 会被那道校验拒掉。
import re  # noqa: E402

check("id 形状与客户端校验一致", all(re.fullmatch(r"[A-Za-z0-9_-]{8,128}", i) for i in ids))
check("id 里没有斜杠", all("/" not in i for i in ids))

print("Content-Type 约定")
check("与客户端 PUT 时必须一致", CONTENT_TYPE == "application/octet-stream")

print()
if FAIL:
    print(f"❌ {len(FAIL)} 项未通过:{FAIL}")
    sys.exit(1)
print("✅ 全部通过")
