"""OTP(阿里云 PNVS 短信认证)、JWT、Apple 登录校验、LoginProvider。密钥只从环境变量读。"""
import base64, hashlib, hmac, json, os, re, secrets, time, urllib.parse, urllib.request, uuid
from typing import Protocol
import jwt

OTP_TTL = 300
OTP_MAX_SENDS_PER_HOUR = 5
OTP_MAX_ATTEMPTS = 5
ACCESS_TTL = 3600
REFRESH_TTL = 30 * 86400

_PHONE_RE = re.compile(r"1[3-9]\d{9}")


class AuthError(Exception):
    pass


def _secret():
    return os.environ["API_JWT_SECRET"]


def normalize_phone(phone) -> str:
    """信任边界校验:非字符串直接拒(别让下游 .strip() 炸出 500),剥掉 +86/86
    前缀后必须是标准的 11 位国内手机号形状。校验失败一律 AuthError,由调用方转 400——
    不做任何"这个号存不存在"的区分。"""
    if not isinstance(phone, str):
        raise AuthError("bad phone")
    p = phone.strip()
    if p.startswith("+86"):
        p = p[3:]
    elif p.startswith("86") and len(p) == 13:
        p = p[2:]
    if not _PHONE_RE.fullmatch(p):
        raise AuthError("bad phone")
    return p


def phone_hash(phone: str) -> str:
    return hmac.new(os.environ["PHONE_HMAC_KEY"].encode(), phone.strip().encode(), hashlib.sha256).hexdigest()


def _code_hash(code: str) -> str:
    return hashlib.sha256(code.encode()).hexdigest()


# ---- 阿里云 PNVS「短信认证」:RPC 风格签名(与 OSS V1 签名同族,stdlib 即可) ----
def _pnvs_call(action: str, params: dict) -> dict:
    ak, sk = os.environ["ALIYUN_ACCESS_KEY_ID"], os.environ["ALIYUN_ACCESS_KEY_SECRET"]
    q = {
        "Action": action, "Version": "2017-05-25", "Format": "JSON",
        "AccessKeyId": ak, "SignatureMethod": "HMAC-SHA1", "SignatureVersion": "1.0",
        "SignatureNonce": str(uuid.uuid4()), "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **params,
    }
    def enc(s):
        return urllib.parse.quote(str(s), safe="~")
    canon = "&".join(f"{enc(k)}={enc(v)}" for k, v in sorted(q.items()))
    sts = "POST&%2F&" + enc(canon)
    sig = base64.b64encode(hmac.new((sk + "&").encode(), sts.encode(), hashlib.sha1).digest()).decode()
    body = urllib.parse.urlencode({**q, "Signature": sig}).encode()
    req = urllib.request.Request("https://dypnsapi.aliyuncs.com/", data=body, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def otp_send(conn, phone: str):
    h = phone_hash(phone)
    row = conn.execute("SELECT sends_in_window, window_started FROM otp WHERE phone_hash=%s", (h,)).fetchone()
    sends = 0
    if row:
        sends, started = row
        if (time.time() - started.timestamp()) > 3600:
            sends = 0
    if sends >= OTP_MAX_SENDS_PER_HOUR:
        raise AuthError("rate_limited")
    code = "000000" if os.environ.get("OTP_DRY_RUN") else f"{secrets.randbelow(10**6):06d}"
    conn.execute(
        # ponytail: 曾经写成 interval '%s seconds' —— 占位符落在字符串字面量里,
        # psycopg 的参数化根本替换不到那儿,Postgres 把整段当字面文本解析,300 秒
        # 变成了 3 秒。make_interval() 把秒数当真正的数值参数传,不再是拼串。
        """INSERT INTO otp(phone_hash, code_hash, expires_at, attempts, sends_in_window, window_started)
           VALUES (%s,%s, now() + make_interval(secs => %s), 0, 1, now())
           ON CONFLICT (phone_hash) DO UPDATE SET code_hash=EXCLUDED.code_hash, expires_at=EXCLUDED.expires_at,
             attempts=0,
             sends_in_window = CASE WHEN now() - otp.window_started > interval '1 hour' THEN 1 ELSE otp.sends_in_window + 1 END,
             window_started = CASE WHEN now() - otp.window_started > interval '1 hour' THEN now() ELSE otp.window_started END""",
        (h, _code_hash(code), OTP_TTL),
    )
    if not os.environ.get("OTP_DRY_RUN"):
        _pnvs_call("SendSmsVerifyCode", {
            "PhoneNumber": phone, "SignName": os.environ["PNVS_SIGN_NAME"],
            "TemplateCode": os.environ["PNVS_TEMPLATE_CODE"],
            "TemplateParam": json.dumps({"code": code}), "ValidTime": str(OTP_TTL),
        })


def otp_check(conn, phone: str, code: str) -> bool:
    h = phone_hash(phone)
    # 计数和读取必须是同一条原子语句(UPDATE ... RETURNING),而且要在比较/抛异常
    # 之前就 commit——否则调用方在 bad code 时抛 AuthError → HTTPException,
    # conn_dep 的 except 分支会 rollback,把这次自增连同其它未提交的改动一起吞掉,
    # 试错次数永远长不到 OTP_MAX_ATTEMPTS,等于没有锁定。
    # `attempts < %s` 的守卫顺带做到:锁定后再撞正确验证码也拿不到 code_hash,不会通过。
    row = conn.execute(
        "UPDATE otp SET attempts = attempts + 1 WHERE phone_hash=%s AND attempts < %s "
        "RETURNING code_hash, expires_at",
        (h, OTP_MAX_ATTEMPTS),
    ).fetchone()
    conn.commit()
    if not row:
        return False
    code_hash, expires_at = row
    if expires_at.timestamp() < time.time():
        return False
    ok = hmac.compare_digest(code_hash, _code_hash(code))
    if ok:
        conn.execute("DELETE FROM otp WHERE phone_hash=%s", (h,))
        conn.commit()
    return ok


def issue_tokens(account_id: str) -> dict:
    now = int(time.time())
    return {
        "access": jwt.encode({"sub": account_id, "typ": "access", "exp": now + ACCESS_TTL}, _secret(), algorithm="HS256"),
        "refresh": jwt.encode({"sub": account_id, "typ": "refresh", "exp": now + REFRESH_TTL}, _secret(), algorithm="HS256"),
    }


def _verify(token: str, typ: str) -> str:
    try:
        p = jwt.decode(token, _secret(), algorithms=["HS256"])
    except jwt.PyJWTError as e:
        raise AuthError(str(e))
    if p.get("typ") != typ:
        raise AuthError("wrong token type")
    return p["sub"]


def verify_access(token: str) -> str:
    return _verify(token, "access")


def verify_refresh(token: str) -> str:
    return _verify(token, "refresh")


# ---- Apple ----
_APPLE_JWKS = {"at": 0, "client": None}


def apple_verify(identity_token: str) -> str:
    try:
        # 先解出 header(格式都不对的垃圾 token 在这步就死),再去拉 JWKS ——
        # 顺序颠倒会导致每个格式错误的请求都白打一次真实网络。
        header = jwt.get_unverified_header(identity_token)
        if time.time() - _APPLE_JWKS["at"] > 3600:
            with urllib.request.urlopen("https://appleid.apple.com/auth/keys", timeout=10) as r:
                _APPLE_JWKS["client"] = jwt.PyJWKSet.from_dict(json.loads(r.read()))
                _APPLE_JWKS["at"] = time.time()
        key = _APPLE_JWKS["client"][header["kid"]]
        p = jwt.decode(identity_token, key.key, algorithms=["RS256"],
                       audience=os.environ["APPLE_BUNDLE_ID"], issuer="https://appleid.apple.com")
    except Exception as e:  # 任何一步失败都是 401,不区分
        raise AuthError(f"apple: {e}")
    return p["sub"]


# ---- LoginProvider:一个接口,三个实现(微信只留位) ----
class LoginProvider(Protocol):
    def login(self, conn, payload: dict) -> str: ...


class PhoneOtpProvider:
    def login(self, conn, payload):
        import db
        phone, code = payload.get("phone", ""), payload.get("code", "")
        if not otp_check(conn, phone, code):
            raise AuthError("bad code")
        h = phone_hash(phone)
        row = db.account_by_phone_hash(conn, h)
        return row[0] if row else db.account_create(conn, phone_hash=h)


class AppleProvider:
    def login(self, conn, payload):
        import db
        sub = apple_verify(payload.get("identity_token", ""))
        row = db.account_by_apple_sub(conn, sub)
        return row[0] if row else db.account_create(conn, apple_sub=sub)


class WeChatProvider:
    """预留。拿到营业执照、开放平台认证后在这里接 code2session;账号表已有 wechat_openid 列。"""
    def login(self, conn, payload):
        raise NotImplementedError("wechat login not available yet")


PROVIDERS = {"otp": PhoneOtpProvider(), "apple": AppleProvider(), "wechat": WeChatProvider()}
