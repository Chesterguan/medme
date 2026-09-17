"""后端测试。对本机 PostgreSQL 跑:
    DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest services/api -q
库不存在先 `createdb -p 5435 medme_api_test`。没有 DATABASE_URL 时整文件跳过。
"""
import base64, hashlib, json, os, re, time
import pytest

DB = os.environ.get("DATABASE_URL")
pytestmark = pytest.mark.skipif(not DB, reason="需要 DATABASE_URL")

os.environ.setdefault("API_JWT_SECRET", "test-secret")
os.environ.setdefault("PHONE_HMAC_KEY", "test-phone-key")
os.environ.setdefault("OTP_DRY_RUN", "1")  # 不真发短信,验证码固定 000000
os.environ.setdefault("APPLE_BUNDLE_ID", "com.medme.mobile")

from fastapi.testclient import TestClient  # noqa: E402
import jwt  # noqa: E402
import db as dbm  # noqa: E402
import auth  # noqa: E402
import oss  # noqa: E402 - Task 15 monkeypatch delete_object 用,与 app.py 里的是同一个模块对象
import app as app_module  # noqa: E402 - 拿模块级常量(如 OBJECT_MAX_BYTES)用,不是重复导入
from app import app  # noqa: E402


@pytest.fixture(autouse=True)
def clean():
    with dbm.connect() as conn:
        dbm.ensure_schema(conn)
        conn.execute("TRUNCATE accounts, devices, profiles, grants, invites, events, objects, usage, otp CASCADE")
        conn.commit()


client = TestClient(app)


def login(phone="13800000001", device="dev-1"):
    assert client.post("/v1/auth/otp", json={"phone": phone}).status_code == 200
    r = client.post("/v1/auth/login", json={"phone": phone, "code": "000000", "device_id": device, "device_name": "test"})
    assert r.status_code == 200, r.text
    return r.json()


def test_otp_login_issues_tokens_and_creates_account_once():
    a = login()
    b = login()
    assert a["account_id"] == b["account_id"]
    assert auth.verify_access(a["access"]) == a["account_id"]
    r = client.post("/v1/auth/refresh", json={"refresh": a["refresh"]})
    assert r.status_code == 200 and "access" in r.json()


def test_otp_wrong_code_and_rate_limit():
    client.post("/v1/auth/otp", json={"phone": "13800000002"})
    r = client.post("/v1/auth/login", json={"phone": "13800000002", "code": "999999", "device_id": "d", "device_name": "d"})
    assert r.status_code == 401
    for _ in range(5):
        client.post("/v1/auth/otp", json={"phone": "13800000003"})
    assert client.post("/v1/auth/otp", json={"phone": "13800000003"}).status_code == 429


def test_wechat_is_501_and_apple_rejects_garbage():
    assert client.post("/v1/auth/wechat", json={}).status_code == 501
    r = client.post("/v1/auth/apple", json={"identity_token": "nope", "device_id": "d", "device_name": "d"})
    assert r.status_code == 401


# ---- 回归:OTP 过期窗口(interval 拼串 bug 会把 300 秒变成 3 秒) ----

def test_otp_expiry_window_is_full_ttl():
    phone = "13800009001"
    with dbm.connect() as conn:
        auth.otp_send(conn, phone)
        conn.commit()
        h = auth.phone_hash(phone)
        row = conn.execute(
            "SELECT EXTRACT(EPOCH FROM (expires_at - now())) FROM otp WHERE phone_hash=%s", (h,)
        ).fetchone()
    remaining = float(row[0])
    assert 290 <= remaining <= 300, remaining


def test_otp_check_rejects_after_expiry():
    phone = "13800009002"
    with dbm.connect() as conn:
        auth.otp_send(conn, phone)
        conn.commit()
        h = auth.phone_hash(phone)
        conn.execute("UPDATE otp SET expires_at = now() - interval '1 second' WHERE phone_hash=%s", (h,))
        conn.commit()
        assert auth.otp_check(conn, phone, "000000") is False


# ---- 回归:试错计数在失败路径上必须真的落盘(否则可以无限撞验证码) ----

def test_otp_lockout_after_max_attempts():
    phone = "13800009003"
    device = "dev-lock"
    assert client.post("/v1/auth/otp", json={"phone": phone}).status_code == 200
    for _ in range(auth.OTP_MAX_ATTEMPTS):
        r = client.post(
            "/v1/auth/login",
            json={"phone": phone, "code": "999999", "device_id": device, "device_name": "d"},
        )
        assert r.status_code == 401
    # 试错次数已经用满,即便这次给的是真码,也必须被锁死拒绝
    r = client.post(
        "/v1/auth/login",
        json={"phone": phone, "code": "000000", "device_id": device, "device_name": "d"},
    )
    assert r.status_code == 401
    h = auth.phone_hash(phone)
    with dbm.connect() as conn:
        row = conn.execute("SELECT attempts FROM otp WHERE phone_hash=%s", (h,)).fetchone()
    assert row[0] == auth.OTP_MAX_ATTEMPTS


# ---- Apple:成功路径 + 各种伪造校验失败 ----

class _FakeJWK:
    def __init__(self, key):
        self.key = key


def _make_apple_token(*, kid="test-kid", aud=None, iss="https://appleid.apple.com", exp_delta=3600, sub="apple-user-1"):
    from cryptography.hazmat.primitives.asymmetric import rsa

    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    payload = {
        "iss": iss,
        "aud": aud if aud is not None else os.environ["APPLE_BUNDLE_ID"],
        "exp": int(time.time()) + exp_delta,
        "sub": sub,
    }
    token = jwt.encode(payload, private_key, algorithm="RS256", headers={"kid": kid})
    return token, private_key.public_key()


def _install_fake_apple_jwks(pubkey, kid):
    # 直接换掉内存里的 JWKS 缓存 + 时间戳,让 apple_verify 跳过真实网络请求。
    auth._APPLE_JWKS["client"] = {kid: _FakeJWK(pubkey)}
    auth._APPLE_JWKS["at"] = time.time()


def test_apple_login_success():
    token, pubkey = _make_apple_token()
    _install_fake_apple_jwks(pubkey, "test-kid")
    r = client.post("/v1/auth/apple", json={"identity_token": token, "device_id": "d", "device_name": "d"})
    assert r.status_code == 200, r.text
    assert "account_id" in r.json()


def test_apple_wrong_aud_rejected():
    token, pubkey = _make_apple_token(aud="com.someone.else")
    _install_fake_apple_jwks(pubkey, "test-kid")
    r = client.post("/v1/auth/apple", json={"identity_token": token, "device_id": "d", "device_name": "d"})
    assert r.status_code == 401


def test_apple_wrong_iss_rejected():
    token, pubkey = _make_apple_token(iss="https://evil.example.com")
    _install_fake_apple_jwks(pubkey, "test-kid")
    r = client.post("/v1/auth/apple", json={"identity_token": token, "device_id": "d", "device_name": "d"})
    assert r.status_code == 401


def test_apple_expired_rejected():
    token, pubkey = _make_apple_token(exp_delta=-3600)
    _install_fake_apple_jwks(pubkey, "test-kid")
    r = client.post("/v1/auth/apple", json={"identity_token": token, "device_id": "d", "device_name": "d"})
    assert r.status_code == 401


def test_apple_unknown_kid_rejected():
    token, pubkey = _make_apple_token(kid="other-kid")
    _install_fake_apple_jwks(pubkey, "test-kid")  # JWKS 里只有 test-kid,token 说自己是 other-kid
    r = client.post("/v1/auth/apple", json={"identity_token": token, "device_id": "d", "device_name": "d"})
    assert r.status_code == 401


# ---- 手机号在信任边界(哈希/发送之前)就要校验 ----

def test_otp_rejects_invalid_phone_format():
    r = client.post("/v1/auth/otp", json={"phone": "12345"})
    assert r.status_code == 400


def test_otp_rejects_non_string_phone():
    r = client.post("/v1/auth/otp", json={"phone": 12345})
    assert r.status_code == 400


def test_otp_accepts_plus86_prefixed_phone():
    r = client.post("/v1/auth/otp", json={"phone": "+8613800009009"})
    assert r.status_code == 200


def _h(tok, device=""):
    return {"Authorization": f"Bearer {tok}", "X-Device-Id": device}


def b64(b):
    return base64.b64encode(b).decode()


def eid(s):
    """事件 id 现在要求 64 位小写 hex(fullmatch)——测试里拿 sha256 凑一个合法形状。"""
    return hashlib.sha256(s.encode()).hexdigest()


def test_keys_profile_family_grant_and_doctor_invite_flow():
    alice = login("13800000010", "a-1")
    bob = login("13800000011", "b-1")
    doc = login("13800000012", "d-1")
    ha, hb, hd = _h(alice["access"]), _h(bob["access"]), _h(doc["access"])
    keys = {"public_key": b64(b"A" * 32), "wrapped_priv_pw": b64(b"pw"), "wrapped_priv_rc": b64(b"rc"),
            "kdf_salt": b64(b"s" * 16), "kdf_params": {"m_kib": 65536, "t": 3, "p": 1}}
    assert client.put("/v1/account/keys", json=keys, headers=ha).status_code == 200
    assert client.get("/v1/account/keys", headers=ha).json()["public_key"] == keys["public_key"]
    assert client.put("/v1/account/keys", json={**keys, "public_key": b64(b"B" * 32)}, headers=hb).status_code == 200

    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk-alice")}, headers=ha).json()["profile_id"]
    mine = client.get("/v1/profiles", headers=ha).json()
    assert mine[0]["role"] == "owner"

    # 家属:按手机号查公钥 → 直接授权 editor 永久
    lk = client.post("/v1/accounts/lookup", json={"phone": "13800000011"}, headers=ha).json()
    assert lk["public_key"] == b64(b"B" * 32)
    g = client.post(f"/v1/profiles/{pid}/grants", json={"grantee_account_id": lk["account_id"], "role": "editor",
                                                      "days": None, "wrapped_profile_key": b64(b"wk-bob")}, headers=ha)
    assert g.status_code == 200
    assert [p for p in client.get("/v1/profiles", headers=hb).json() if p["profile_id"] == pid][0]["role"] == "editor"
    # bob 不是 owner,不能再授权别人
    assert client.post(f"/v1/profiles/{pid}/grants", json={"grantee_account_id": doc["account_id"], "role": "viewer",
                                                         "days": 15, "wrapped_profile_key": b64(b"x")}, headers=hb).status_code == 403

    # 医生:患者出示邀请(15 天 viewer),医生兑换
    token = "T" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 15, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
                                                            "wrapped_key_by_token": b64(b"wk-token"), "invite_ttl_s": 600}, headers=ha).json()
    r = client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": "wrong"}, headers=hd)
    assert r.status_code == 404
    r = client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hd)
    assert r.status_code == 200 and r.json()["role"] == "viewer"
    exp = r.json()["expires_at"]
    assert 14 * 86400 < (time.mktime(time.strptime(exp[:19], "%Y-%m-%dT%H:%M:%S")) - time.time()) < 16 * 86400
    assert client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hd).status_code == 410
    gid = r.json()["grant_id"]
    assert client.put(f"/v1/profiles/{pid}/grants/{gid}/key", json={"wrapped_profile_key": b64(b"wk-doc")}, headers=hd).status_code == 200
    # owner 撤销
    assert client.delete(f"/v1/profiles/{pid}/grants/{gid}", headers=ha).status_code == 200
    assert all(p["profile_id"] != pid for p in client.get("/v1/profiles", headers=hd).json())


def test_transfer_makes_new_owner_and_demotes_old():
    doc = login("13800000020", "d-1")
    pat = login("13800000021", "p-1")
    hd, hp = _h(doc["access"]), _h(pat["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=hd).json()["profile_id"]
    token = "X" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "owner", "days": None, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
                                                            "wrapped_key_by_token": b64(b"wk-t"), "invite_ttl_s": 86400 * 15}, headers=hd).json()
    assert client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hp).status_code == 200
    roles = {p["profile_id"]: p["role"] for p in client.get("/v1/profiles", headers=hp).json()}
    assert roles[pid] == "owner"
    roles = {p["profile_id"]: p["role"] for p in client.get("/v1/profiles", headers=hd).json()}
    assert roles[pid] == "editor"


def test_device_approval_handoff():
    a = login("13800000030", "old")
    ha = _h(a["access"], "old")
    b = login("13800000030", "new")
    hb = _h(b["access"], "new")
    assert client.post("/v1/devices/request", json={"eph_public": b64(b"E" * 32)}, headers=hb).status_code == 200
    devs = client.get("/v1/devices", headers=ha).json()
    pending = [d for d in devs if d["device_id"] == "new"][0]
    assert pending["eph_public"] == b64(b"E" * 32)
    assert client.post("/v1/devices/approve", json={"device_id": "new", "approved_priv": b64(b"sealed")}, headers=ha).status_code == 200
    r = client.get("/v1/devices/approval", params={"device_id": "new"}, headers=hb)
    assert r.json()["approved_priv"] == b64(b"sealed")
    assert client.get("/v1/devices/approval", params={"device_id": "new"}, headers=hb).json()["approved_priv"] is None


# ---- UX 第二轮 复审 I4:新的批准请求作废旧批准 ----

def test_new_device_request_voids_previous_approval():
    """新设备重新生成一张码(= 新的临时密钥对)之后,上一次的批准必须作废。

    不作废的后果是一把**用旧临时公钥封的账号私钥**继续躺在服务端等着被取走,而新设备
    此刻手里的临时私钥已经换了 —— 它取走之后拆不开,只看到"批准了却还是进不去";
    同时那份密文还在服务端多活最多 24 小时(`APPROVAL_TTL_HOURS`),而它是账号私钥。
    """
    a = login("13800000031", "old31")
    ha = _h(a["access"], "old31")
    b = login("13800000031", "new31")
    hb = _h(b["access"], "new31")

    assert client.post("/v1/devices/request", json={"eph_public": b64(b"E" * 32)}, headers=hb).status_code == 200
    assert client.post("/v1/devices/approve", json={"device_id": "new31", "approved_priv": b64(b"sealed-old")}, headers=ha).status_code == 200

    # 新设备又生成了一张码(新的临时密钥对)。
    assert client.post("/v1/devices/request", json={"eph_public": b64(b"F" * 32)}, headers=hb).status_code == 200

    r = client.get("/v1/devices/approval", params={"device_id": "new31"}, headers=hb)
    assert r.json()["approved_priv"] is None, "旧批准必须随新请求一起作废"
    devs = {d["device_id"]: d for d in client.get("/v1/devices", headers=ha).json()}
    assert devs["new31"]["eph_public"] == b64(b"F" * 32)
    assert devs["new31"]["approved"] is False


# ---- fix round 1: item 1 —— grant_upsert 不能把 owner 降级 ----

def test_grant_create_self_target_rejected_owner_unchanged():
    owner = login("13800000090", "o1")
    ho = _h(owner["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    r = client.post(f"/v1/profiles/{pid}/grants", json={"grantee_account_id": owner["account_id"], "role": "editor",
                                                          "days": None, "wrapped_profile_key": b64(b"evil")}, headers=ho)
    assert r.status_code == 400
    with dbm.connect() as conn:
        rows = conn.execute("SELECT role FROM grants WHERE profile_id=%s", (pid,)).fetchall()
    assert [row[0] for row in rows] == ["owner"]


def test_invite_redeem_by_issuer_rejected_owner_unchanged():
    owner = login("13800000091", "o1")
    ho = _h(owner["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    token = "S" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "editor", "days": None,
        "token_hash": hashlib.sha256(token.encode()).hexdigest(), "wrapped_key_by_token": b64(b"wk-t"),
        "invite_ttl_s": 600}, headers=ho).json()
    r = client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=ho)
    assert r.status_code == 400
    with dbm.connect() as conn:
        rows = conn.execute("SELECT role FROM grants WHERE profile_id=%s", (pid,)).fetchall()
    assert [row[0] for row in rows] == ["owner"]


# ---- fix round 1: item 2 —— 邀请兑换的竞态 + 用 DB 时间 ----

def test_invite_redeem_expired_via_db_time_is_410():
    owner = login("13800000092", "o1")
    doc = login("13800000093", "d1")
    ho, hd = _h(owner["access"]), _h(doc["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    token = "E" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 5,
        "token_hash": hashlib.sha256(token.encode()).hexdigest(), "wrapped_key_by_token": b64(b"wk-t"),
        "invite_ttl_s": 600}, headers=ho).json()
    with dbm.connect() as conn:
        conn.execute("UPDATE invites SET expires_at = now() - interval '1 second' WHERE id=%s", (inv["invite_id"],))
        conn.commit()
    r = client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hd)
    assert r.status_code == 410


def test_invite_redeem_second_attempt_410():
    owner = login("13800000094", "o1")
    doc = login("13800000095", "d1")
    ho, hd = _h(owner["access"]), _h(doc["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    token = "F" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 5,
        "token_hash": hashlib.sha256(token.encode()).hexdigest(), "wrapped_key_by_token": b64(b"wk-t"),
        "invite_ttl_s": 600}, headers=ho).json()
    assert client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hd).status_code == 200
    assert client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hd).status_code == 410


# ---- fix round 1: item 3 —— 设备批准要绑定发起批准的那台设备 ----

def test_untrusted_device_cannot_approve():
    a = login("13800000096", "d1")
    b = login("13800000096", "d2")
    hb = _h(b["access"], "d2")
    client.post("/v1/devices/request", json={"eph_public": b64(b"E" * 32)}, headers=hb)
    # d2 自己还挂在"等批准"状态,不可信,不能批准任何设备(包括它自己)
    r = client.post("/v1/devices/approve", json={"device_id": "d2", "approved_priv": b64(b"x")}, headers=hb)
    assert r.status_code == 403


def test_device_approve_and_approval_scoped_to_account_not_just_device_id():
    a_old = login("13800000097", "old")
    a_new = login("13800000097", "new2")
    attacker = login("13800000098", "x1")
    h_old, h_new = _h(a_old["access"], "old"), _h(a_new["access"], "new2")
    client.post("/v1/devices/request", json={"eph_public": b64(b"E" * 32)}, headers=h_new)
    assert client.post("/v1/devices/approve", json={"device_id": "new2", "approved_priv": b64(b"sealed")}, headers=h_old).status_code == 200

    # 攻击者拿自己的账号 token,冒充 X-Device-Id="new2" 去批准/取批准——account_id
    # 那一列会把它挡在门外,不能碰到 A 账号下真正的 new2 那一行。approve 还会先
    # 撞上"批准者自己的设备必须可信"那道检查(攻击者账号下根本没有 new2 这台设备,
    # 天然不可信)——403 也好、404 也好,只要没碰到 A 的那一行就算安全。
    h_attacker_as_new2 = {"Authorization": f"Bearer {attacker['access']}", "X-Device-Id": "new2"}
    r = client.post("/v1/devices/approve", json={"device_id": "new2", "approved_priv": b64(b"evil")}, headers=h_attacker_as_new2)
    assert r.status_code in (403, 404)
    r = client.get("/v1/devices/approval", params={"device_id": "new2"}, headers=h_attacker_as_new2)
    assert r.status_code == 200 and r.json()["approved_priv"] is None

    with dbm.connect() as conn:
        row = conn.execute("SELECT approved_priv FROM devices WHERE account_id=%s AND device_id='new2'", (a_old["account_id"],)).fetchone()
    assert row[0] == b"sealed"


# ---- Task 16 item 4 —— approved_priv 超过 24h 没被取走就清掉 ----

def test_stale_approved_priv_swept_when_collected_after_24h():
    old = login("13800000130", "old")
    new = login("13800000130", "new")
    h_old, h_new = _h(old["access"], "old"), _h(new["access"], "new")
    client.post("/v1/devices/request", json={"eph_public": b64(b"E" * 32)}, headers=h_new)
    assert client.post("/v1/devices/approve", json={"device_id": "new", "approved_priv": b64(b"sealed")}, headers=h_old).status_code == 200
    with dbm.connect() as conn:
        conn.execute("UPDATE devices SET approved_at = now() - interval '25 hours' WHERE account_id=%s AND device_id='new'", (old["account_id"],))
        conn.commit()
    r = client.get("/v1/devices/approval", params={"device_id": "new"}, headers=h_new)
    assert r.json()["approved_priv"] is None, "超过 24h 没取走,取批准这一步本身先扫掉,取不到东西"


def test_stale_approved_priv_swept_by_a_later_device_approve_call():
    old = login("13800000132", "old")
    stale = login("13800000132", "stale")
    fresh = login("13800000132", "fresh")
    h_old = _h(old["access"], "old")
    h_stale, h_fresh = _h(stale["access"], "stale"), _h(fresh["access"], "fresh")
    client.post("/v1/devices/request", json={"eph_public": b64(b"E" * 32)}, headers=h_stale)
    assert client.post("/v1/devices/approve", json={"device_id": "stale", "approved_priv": b64(b"sealed")}, headers=h_old).status_code == 200
    with dbm.connect() as conn:
        conn.execute("UPDATE devices SET approved_at = now() - interval '25 hours' WHERE account_id=%s AND device_id='stale'", (old["account_id"],))
        conn.commit()
    client.post("/v1/devices/request", json={"eph_public": b64(b"F" * 32)}, headers=h_fresh)
    assert client.post("/v1/devices/approve", json={"device_id": "fresh", "approved_priv": b64(b"sealed2")}, headers=h_old).status_code == 200
    with dbm.connect() as conn:
        row = conn.execute("SELECT approved_priv, approved_at FROM devices WHERE account_id=%s AND device_id='stale'", (old["account_id"],)).fetchone()
    assert row == (None, None), "批准另一台设备这一步也该顺手扫掉过期的批准"


def test_fresh_approved_priv_not_swept_within_24h():
    old = login("13800000133", "old")
    new = login("13800000133", "new")
    h_old, h_new = _h(old["access"], "old"), _h(new["access"], "new")
    client.post("/v1/devices/request", json={"eph_public": b64(b"E" * 32)}, headers=h_new)
    assert client.post("/v1/devices/approve", json={"device_id": "new", "approved_priv": b64(b"sealed")}, headers=h_old).status_code == 200
    r = client.get("/v1/devices/approval", params={"device_id": "new"}, headers=h_new)
    assert r.json()["approved_priv"] == b64(b"sealed")


# ---- fix round 1: item 4 —— /v1/accounts/lookup 要走 normalize_phone,且限流 ----

def test_accounts_lookup_normalizes_plus86_and_rate_limits():
    alice = login("13800000099", "a1")
    bob = login("13800000100", "b1")
    ha = _h(alice["access"])
    keys = {"public_key": b64(b"K" * 32), "wrapped_priv_pw": b64(b"pw"), "wrapped_priv_rc": b64(b"rc"),
            "kdf_salt": b64(b"s" * 16), "kdf_params": {"m_kib": 65536, "t": 3, "p": 1}}
    client.put("/v1/account/keys", json=keys, headers=_h(bob["access"]))
    r = client.post("/v1/accounts/lookup", json={"phone": "+8613800000100"}, headers=ha)
    assert r.status_code == 200 and r.json()["account_id"] == bob["account_id"]
    for _ in range(19):
        assert client.post("/v1/accounts/lookup", json={"phone": "13800000100"}, headers=ha).status_code == 200
    assert client.post("/v1/accounts/lookup", json={"phone": "13800000100"}, headers=ha).status_code == 429


def test_accounts_lookup_distinguishes_unknown_phone_from_keyless_account():
    """B4:「查无此人」与「注册过但还没设账号口令」是两件事,客户端要能分开说。

    在这之前两者都是 404,于是家属看到的是「没有找到使用该手机号的账号」——
    而最常见的真实情况恰恰是后者(父母登录了、卡在设口令那一步),那句话是错误
    归因:他会去确认手机号、重输、放弃,而真正要做的事在对方手机上。"""
    alice = login("13800000150", "a1")
    ha = _h(alice["access"])

    # ① 压根没有这个账号 → 404
    r = client.post("/v1/accounts/lookup", json={"phone": "13800000199"}, headers=ha)
    assert r.status_code == 404, r.text
    assert r.json()["detail"] == "not found"

    # ② 注册过,但没设过账号密钥 → 409 no_keys(不是 404)
    keyless = login("13800000151", "k1")
    r = client.post("/v1/accounts/lookup", json={"phone": "13800000151"}, headers=ha)
    assert r.status_code == 409, r.text
    assert r.json()["detail"] == "no_keys"

    # ③ 设完密钥之后就是正常的 200,带公钥
    keys = {"public_key": b64(b"K" * 32), "wrapped_priv_pw": b64(b"pw"), "wrapped_priv_rc": b64(b"rc"),
            "kdf_salt": b64(b"s" * 16), "kdf_params": {"m_kib": 65536, "t": 3, "p": 1}}
    assert client.put("/v1/account/keys", json=keys, headers=_h(keyless["access"])).status_code == 200
    r = client.post("/v1/accounts/lookup", json={"phone": "13800000151"}, headers=ha)
    assert r.status_code == 200 and r.json()["public_key"] == b64(b"K" * 32)


def test_accounts_lookup_rate_limit_applies_to_404_and_409_branches():
    """评审 Minor 19:限流(`app.py` 的 `lookup_rate_ok`)写在**分支之前**,所以
    三种结果同等消耗配额 —— 但原来只有 200 那条分支被打到过 429,于是把限流那两行
    和分支顺序调换一下仍然能过 CI。**按 404 枚举是更便宜的攻击形状**(不需要先知道
    任何一个真实号码),所以这两条分支才更需要被钉住。"""
    alice = login("13800000160", "a1")
    ha = _h(alice["access"])

    # ① 只打"查无此人"(404)也会把配额烧完 → 第 21 次是 429,不是 404。
    for _ in range(dbm.LOOKUP_MAX_PER_HOUR):
        assert client.post("/v1/accounts/lookup", json={"phone": "13800000161"}, headers=ha).status_code == 404
    assert client.post("/v1/accounts/lookup", json={"phone": "13800000161"}, headers=ha).status_code == 429

    # ② 换一个调用者(配额按调用者账号算),只打"注册过但没密钥"(409)同理。
    bob = login("13800000162", "b1")
    hb = _h(bob["access"])
    login("13800000163", "k1")  # 有账号、没设过密钥
    for _ in range(dbm.LOOKUP_MAX_PER_HOUR):
        assert client.post("/v1/accounts/lookup", json={"phone": "13800000163"}, headers=hb).status_code == 409
    assert client.post("/v1/accounts/lookup", json={"phone": "13800000163"}, headers=hb).status_code == 429


def test_accounts_lookup_get_method_removed():
    """Task 16 item 2:手机号从 GET 查询串换成 POST body,老的 GET 路由不该
    还在——405(方法不存在),不是悄悄换成别的语义。"""
    alice = login("13800000145", "a1")
    ha = _h(alice["access"])
    assert client.get("/v1/accounts/lookup", params={"phone": "13800000100"}, headers=ha).status_code == 405


# ---- Task 16 item 1 —— GET /v1/profiles/{pid}/grants(owner 专用,不带手机号/姓名) ----

def test_grants_list_owner_only_and_shape_excludes_phone_and_name():
    owner = login("13800000140", "o1")
    bob = login("13800000141", "b1")
    ho, hb = _h(owner["access"]), _h(bob["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    gid = client.post(f"/v1/profiles/{pid}/grants", json={"grantee_account_id": bob["account_id"], "role": "editor",
                                                            "days": None, "wrapped_profile_key": b64(b"wk-bob")}, headers=ho).json()["grant_id"]

    r = client.get(f"/v1/profiles/{pid}/grants", headers=ho)
    assert r.status_code == 200
    rows = r.json()
    for row in rows:
        assert set(row.keys()) == {"grant_id", "grantee_kind", "role", "expires_at", "created_at"}, \
            "绝不能带 phone/name——服务端本来就没存这些"
    bob_row = [row for row in rows if row["grant_id"] == gid][0]
    assert bob_row["role"] == "editor" and bob_row["grantee_kind"] == "account"

    # 非 owner(包括被授权者自己)查不到这个列表。
    assert client.get(f"/v1/profiles/{pid}/grants", headers=hb).status_code == 403


# ---- fix round 1: item 5 —— 带 DB 断言的负授权测试 ----

def test_grant_delete_by_non_owner_forbidden_and_row_unchanged():
    owner = login("13800000101", "o1")
    outsider = login("13800000102", "x1")
    ho, hx = _h(owner["access"]), _h(outsider["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    with dbm.connect() as conn:
        owner_gid = conn.execute("SELECT id FROM grants WHERE profile_id=%s AND role='owner'", (pid,)).fetchone()[0]
    assert client.delete(f"/v1/profiles/{pid}/grants/{owner_gid}", headers=hx).status_code == 403
    with dbm.connect() as conn:
        row = conn.execute("SELECT role FROM grants WHERE id=%s", (owner_gid,)).fetchone()
    assert row[0] == "owner"


def test_invite_create_by_non_owner_forbidden():
    owner = login("13800000103", "o1")
    outsider = login("13800000104", "x1")
    ho, hx = _h(owner["access"]), _h(outsider["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    r = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 5,
        "token_hash": hashlib.sha256(b"x").hexdigest(), "wrapped_key_by_token": b64(b"x"), "invite_ttl_s": 60}, headers=hx)
    assert r.status_code == 403


def test_account_with_no_grant_forbidden_on_grant_create():
    owner = login("13800000105", "o1")
    stranger = login("13800000106", "s1")
    ho, hs = _h(owner["access"]), _h(stranger["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    r = client.post(f"/v1/profiles/{pid}/grants", json={"grantee_account_id": stranger["account_id"], "role": "viewer",
        "days": 5, "wrapped_profile_key": b64(b"x")}, headers=hs)
    assert r.status_code == 403


def test_cross_account_grant_key_backfill_forbidden_and_row_unchanged():
    owner = login("13800000107", "o1")
    bob = login("13800000108", "b1")
    doc = login("13800000109", "d1")
    ho, hd = _h(owner["access"]), _h(doc["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    gid = client.post(f"/v1/profiles/{pid}/grants", json={"grantee_account_id": bob["account_id"], "role": "editor",
        "days": None, "wrapped_profile_key": b64(b"wk-bob")}, headers=ho).json()["grant_id"]
    r = client.put(f"/v1/profiles/{pid}/grants/{gid}/key", json={"wrapped_profile_key": b64(b"evil")}, headers=hd)
    assert r.status_code == 403
    with dbm.connect() as conn:
        row = conn.execute("SELECT wrapped_profile_key FROM grants WHERE id=%s", (gid,)).fetchone()
    assert row[0] == b"wk-bob"


def test_keys_get_404_when_unset():
    a = login("13800000110", "a1")
    assert client.get("/v1/account/keys", headers=_h(a["access"])).status_code == 404


def test_no_bearer_401():
    assert client.get("/v1/profiles").status_code == 401


# ---- fix round 1: item 7 —— days/invite_ttl_s 上限 ----

def test_invite_days_capped_at_grant_doctor_days():
    owner = login("13800000111", "o1")
    ho = _h(owner["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 3650,
        "token_hash": hashlib.sha256(b"cap").hexdigest(), "wrapped_key_by_token": b64(b"x"),
        "invite_ttl_s": 999999}, headers=ho).json()
    with dbm.connect() as conn:
        row = conn.execute("SELECT grant_days FROM invites WHERE id=%s", (inv["invite_id"],)).fetchone()
    assert row[0] == dbm.GRANT_DOCTOR_DAYS == 15


# ---- Task 11 review round 1: item 2 —— invite_ttl_s 上限按角色分开(viewer 600s,owner 15 天)----

def test_invite_ttl_s_capped_by_role_viewer_600_owner_15_days():
    owner = login("13800000113", "o1")
    ho = _h(owner["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    viewer_inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 15,
        "token_hash": hashlib.sha256(b"viewer-ttl-cap").hexdigest(), "wrapped_key_by_token": b64(b"x"),
        "invite_ttl_s": 999999}, headers=ho).json()
    owner_inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "owner", "days": None,
        "token_hash": hashlib.sha256(b"owner-ttl-cap").hexdigest(), "wrapped_key_by_token": b64(b"y"),
        "invite_ttl_s": 999999999}, headers=ho).json()
    with dbm.connect() as conn:
        viewer_ttl = conn.execute(
            "SELECT extract(epoch FROM expires_at - created_at) FROM invites WHERE id=%s", (viewer_inv["invite_id"],)
        ).fetchone()[0]
        owner_ttl = conn.execute(
            "SELECT extract(epoch FROM expires_at - created_at) FROM invites WHERE id=%s", (owner_inv["invite_id"],)
        ).fetchone()[0]
    assert dbm.INVITE_TTL_CAP_S == 600
    assert dbm.INVITE_TTL_CAP_OWNER_S == 15 * 86400
    assert abs(viewer_ttl - dbm.INVITE_TTL_CAP_S) < 2
    assert abs(owner_ttl - dbm.INVITE_TTL_CAP_OWNER_S) < 2


# ---- Task 6: 事件推拉、对象预签名、LLM 代理 ----

def test_events_push_pull_role_enforced_and_since_filter():
    a = login("13800000040", "a")
    v = login("13800000041", "v")
    ha, hv = _h(a["access"]), _h(v["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    token = "V" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 15, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
                                                            "wrapped_key_by_token": b64(b"w"), "invite_ttl_s": 600}, headers=ha).json()
    client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hv)
    evs = [{"device_id": "a", "seq": i, "event_id": eid(f"e{i}"), "ts": "2026-09-11T00:00:00Z", "ciphertext": b64(b"c%d" % i)} for i in (1, 2, 3)]
    assert client.post(f"/v1/profiles/{pid}/events", json=evs, headers=ha).status_code == 200
    assert client.post(f"/v1/profiles/{pid}/events", json=evs, headers=ha).status_code == 200  # 幂等
    assert client.post(f"/v1/profiles/{pid}/events", json=evs, headers=hv).status_code == 403   # viewer 不能写
    r = client.get(f"/v1/profiles/{pid}/events", params={"since": json.dumps({"a": 1})}, headers=hv)
    got = r.json()
    assert [e["seq"] for e in got] == [2, 3]
    assert got[0]["ciphertext"] == b64(b"c2")
    assert json.loads(r.headers["X-Seq-Map"]) == {"a": 3}


def test_events_push_by_viewer_forbidden_event_not_written():
    a = login("13800000042", "a")
    v = login("13800000043", "v")
    ha, hv = _h(a["access"]), _h(v["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    token = "W" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 15, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
                                                            "wrapped_key_by_token": b64(b"w"), "invite_ttl_s": 600}, headers=ha).json()
    client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hv)
    ev = [{"device_id": "v", "seq": 1, "event_id": eid("ev1"), "ts": "2026-09-11T00:00:00Z", "ciphertext": b64(b"x")}]
    assert client.post(f"/v1/profiles/{pid}/events", json=ev, headers=hv).status_code == 403
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM events WHERE profile_id=%s", (pid,)).fetchone()[0] == 0


def test_events_pull_forbidden_without_grant():
    a = login("13800000044", "a")
    stranger = login("13800000045", "s")
    ha, hs = _h(a["access"]), _h(stranger["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    assert client.get(f"/v1/profiles/{pid}/events", headers=hs).status_code == 403
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM grants WHERE profile_id=%s AND grantee_id=%s", (pid, stranger["account_id"])).fetchone()[0] == 0


def test_object_sign_registers_and_counts_storage():
    os.environ.update({"OSS_ACCESS_KEY_ID": "AK", "OSS_ACCESS_KEY_SECRET": "SK", "OSS_BUCKET": "medme-vault", "OSS_ENDPOINT": "oss-cn-hangzhou.aliyuncs.com"})
    a = login("13800000050", "a")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    r = client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": "ab" * 32, "verb": "PUT", "size": 1234}, headers=ha).json()
    assert r["url"].startswith("https://medme-vault.oss-cn-hangzhou.aliyuncs.com/v/") and "Signature=" in r["url"]
    assert client.get(f"/v1/profiles/{pid}/objects", headers=ha).json() == ["ab" * 32]
    with dbm.connect() as conn:
        assert conn.execute("SELECT storage_bytes FROM usage WHERE account_id=%s", (a["account_id"],)).fetchone()[0] == 1234
    assert client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": "zz", "verb": "PUT", "size": 1}, headers=ha).status_code == 400


def test_object_sign_forbidden_without_grant():
    a = login("13800000051", "a")
    stranger = login("13800000052", "s")
    ha, hs = _h(a["access"]), _h(stranger["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    oid = "cd" * 32
    assert client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": oid, "verb": "PUT", "size": 999}, headers=hs).status_code == 403
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM objects WHERE profile_id=%s AND object_id=%s", (pid, oid)).fetchone()[0] == 0
        row = conn.execute("SELECT storage_bytes FROM usage WHERE account_id=%s", (stranger["account_id"],)).fetchone()
        assert row is None


def test_extract_system_prompt_matches_eval_fixture():
    # 两边(这里的代理 + 评测臂 packages/ocr/examples/medrep_llm.rs)必须发同一段
    # prompt 给 DeepSeek,否则线上抽取和评测数字量的不是同一个模型行为。两边都从
    # packages/deid/prompts/ 的同一份文件读,这里核对读到的确实是那份文件。
    import extract
    prompts_dir = os.path.join(os.path.dirname(extract.__file__), "..", "..", "packages", "deid", "prompts")
    with open(os.path.join(prompts_dir, "extract_v1_system.txt"), encoding="utf-8") as f:
        assert extract.SYSTEM_PROMPT_V1 == f.read()
    with open(os.path.join(prompts_dir, "extract_v2_system.txt"), encoding="utf-8") as f:
        assert extract.SYSTEM_PROMPT_V2 == f.read()
    with open(os.path.join(prompts_dir, "extract_v1_image_user.txt"), encoding="utf-8") as f:
        assert extract.IMAGE_USER_TEXT == f.read()
    with open(os.path.join(prompts_dir, "extract_params.json"), encoding="utf-8") as f:
        assert extract.REQUEST_PARAMS == json.load(f)

    # 上面几条只证明"Python 自己读自己写的路径"(同义反复):没有任何东西核对过
    # Rust 评测臂的 include_str! 真的指向同一份文件——把 SYSTEM_V2 的 include_str!
    # 误写成指向 v1 文件,照样编译、照样通过上面的断言(fix round 1 review finding 2)。
    # 这里真的解析 medrep_llm.rs 的源码,取出三个常量各自的 include_str! 路径,
    # 相对 .rs 文件本身所在目录解出来,拿文件内容跟 Python 读到的逐字节比。
    rust_src_path = os.path.join(prompts_dir, "..", "..", "ocr", "examples", "medrep_llm.rs")
    with open(rust_src_path, encoding="utf-8") as f:
        rust_src = f.read()
    includes = dict(re.findall(r'const (\w+): &str = include_str!\("([^"]+)"\);', rust_src))
    rust_dir = os.path.dirname(rust_src_path)
    for const_name, py_value in (("SYSTEM", extract.SYSTEM_PROMPT_V1), ("SYSTEM_V2", extract.SYSTEM_PROMPT_V2)):
        with open(os.path.join(rust_dir, includes[const_name]), encoding="utf-8") as f:
            assert f.read() == py_value, const_name
    with open(os.path.join(rust_dir, includes["REQUEST_PARAMS"]), encoding="utf-8") as f:
        assert json.load(f) == extract.REQUEST_PARAMS


def test_extract_v2_prompt_is_v1_verbatim_plus_facts():
    # fix round 1(review finding 1):brief 原文让 v2 的开场白重写了一遍 v1 的话术,
    # 于是 Task 8 的 MedRepBench 回归门比较 v1/v2 时,召回涨跌分不清是 facts 拖累的
    # 还是纯措辞换了。改成硬规矩钉住:v2 必须是"v1 原文一字不改 + facts 追加",
    # 这样以后谁手滑改了 v2 的开场白,这条测试立刻红。
    import extract
    v1_without_closing_brace = extract.SYSTEM_PROMPT_V1[:-1]
    assert extract.SYSTEM_PROMPT_V2.startswith(v1_without_closing_brace)
    appended = extract.SYSTEM_PROMPT_V2[len(v1_without_closing_brace):]
    assert appended.startswith(',"facts":[')


def test_extract_v2_prompt_names_every_fact_field_the_rust_type_has():
    # prompt 里的键和 deid::Fact 的字段名对不上,模型吐出来的东西就静默丢字段。
    import extract
    for key in ["organ_involvement", "flare", "hospitalization", "biopsy", "infusion",
                "dose_change", "scale", "imaging_finding", "infection", "pregnancy",
                "vaccination", "exam_done", "evidence", "date_start", "date_end"]:
        assert key in extract.SYSTEM_PROMPT_V2, key
    # 族级:prompt 里不许出现任何具体病名 —— 服务端看不出用户是哪个病(spec §8)。
    # "SLE" 不能直接当子串判:量表名 SLEDAI 是 spec §3 规定的族级 scale 枚举之一
    # (六个病的量表混列同一个 enum,单看一份 prompt 分不出用户是哪个病),朴素子串
    # 会把它和 SLEDAI 里连着的这三个字母撞在一起误报,所以改判"每次出现都在 SLEDAI 里"。
    for banned in ["红斑狼疮", "多发性硬化", "重症肌无力", "IBD", "NMOSD"]:
        assert banned not in extract.SYSTEM_PROMPT_V2, banned
    assert extract.SYSTEM_PROMPT_V2.count("SLE") == extract.SYSTEM_PROMPT_V2.count("SLEDAI")


def test_extract_rejects_schema_three_but_accepts_one_and_two(monkeypatch):
    import extract
    seen = {}

    def fake(arm, model, messages):
        seen["system"] = messages[0]["content"]
        return {"choices": [{"finish_reason": "stop", "message": {"content": "{}"}}], "usage": {}}

    monkeypatch.setattr(extract, "_call_deepseek", fake)
    extract.run({"mode": "text", "schema": 1, "payload": "x"})
    assert seen["system"] == extract.SYSTEM_PROMPT_V1
    extract.run({"mode": "text", "schema": 2, "payload": "x"})
    assert seen["system"] == extract.SYSTEM_PROMPT_V2
    for bad in (3, 0, "2", None):
        with pytest.raises(extract.SchemaError):
            extract.run({"mode": "text", "schema": bad, "payload": "x"})


def test_extract_route_picks_prompt_by_schema_and_mode(monkeypatch):
    # fix round 1(review finding 3):原来这条整个 monkeypatch 掉 extract.run,
    # schema 闸根本没跑就"过"了。改成只 stub 网络那一层 `_call_deepseek`,让
    # run() 里真正的 schema 判断、prompt 选择跑一遍,经真实的 /v1/extract 路由,
    # 四种 schema×mode 组合都测——图片档最容易在未来重构里被漏掉。
    import extract
    seen = {}

    def fake(arm, model, messages):
        seen["system"] = messages[0]["content"]
        return {"choices": [{"message": {"content": "{}"}}], "usage": {}}

    monkeypatch.setattr(extract, "_call_deepseek", fake)
    a = login("13800000100", "a")
    h = _h(a["access"])
    cases = [
        ({"mode": "text", "schema": 1, "payload": "x"}, extract.SYSTEM_PROMPT_V1),
        ({"mode": "image", "schema": 1, "payload": "AAAA"}, extract.SYSTEM_PROMPT_V1),
        ({"mode": "text", "schema": 2, "payload": "x"}, extract.SYSTEM_PROMPT_V2),
        ({"mode": "image", "schema": 2, "payload": "AAAA"}, extract.SYSTEM_PROMPT_V2),
    ]
    for body, expected_prompt in cases:
        r = client.post("/v1/extract", json=body, headers=h)
        assert r.status_code == 200, r.text
        assert seen["system"] == expected_prompt, body


def test_extract_request_bounds_the_model_output(monkeypatch):
    # `deepseek-flash` 是推理模型:不封顶时 reasoning_tokens 自己跑飞,整趟抽取顶爆
    # 上游超时,用户侧就是「什么都没有」(extract-repro-report.md §1)。实测同一张图
    # 60.7 s 超时失败 → 3.8 s / 887 completion token / 19 条 lab。两个参数缺一不可:
    # 只加 max_tokens 会在推理中途被截断(实测 reasoning_effort=high 配 6000 上限,
    # 24 s 后 content 是空的),所以请求体里两个都得在。
    import extract
    sent = {}

    class _Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return json.dumps({"choices": [{"message": {"content": '{"doc_type":"lab","labs":[]}'}}], "usage": {}}).encode()

    def _fake_urlopen(req, timeout=None):
        sent["body"] = json.loads(req.data)
        sent["timeout"] = timeout
        return _Resp()

    monkeypatch.setenv("DEEPSEEK_API_KEY", "k")
    monkeypatch.setattr(extract.urllib.request, "urlopen", _fake_urlopen)
    # **按臂取参数**:文本档 16384,图片档 8192。取错臂 = 线上和评测发的不是同一个
    # 请求。文本档那一档是 task-23 实测比出来的:8192 在 50 份抽样上截断了 5 份
    # (10%),抬到 16384 后那 5 份全部一次过。
    extract.run({"mode": "text", "schema": 1, "payload": "x"})
    assert sent["body"]["max_tokens"] == extract.REQUEST_PARAMS["text"]["max_tokens"] == 16384
    assert sent["body"]["reasoning_effort"] == extract.REQUEST_PARAMS["text"]["reasoning_effort"] == "low"
    extract.run({"mode": "image", "schema": 1, "payload": "AAAA"})
    assert sent["body"]["max_tokens"] == extract.REQUEST_PARAMS["image"]["max_tokens"] == 8192
    assert sent["body"]["reasoning_effort"] == extract.REQUEST_PARAMS["image"]["reasoning_effort"] == "low"
    # 客户端的 extractTimeout(cloud_extract.dart)必须比这个宽。
    assert sent["timeout"] == 120


def test_extract_truncated_by_max_tokens_is_502_not_a_half_table(monkeypatch):
    # `finish_reason == "length"` = 被 MAX_TOKENS 截断。内容偶尔会恰好断在一个合法的
    # JSON 位置上,于是一份**缺了后半张表**的抽取会被当成完整结果落进保险箱。
    # 必须算上游错误(502),让客户端退回正则。
    import extract
    monkeypatch.setattr(extract, "_call_deepseek", lambda arm, model, messages: {
        "choices": [{"finish_reason": "length", "message": {"content": '{"doc_type":"lab","labs":[]}'}}],
        "usage": {"prompt_tokens": 1, "completion_tokens": 6000},
    })
    a = login("13800000067", "a")
    r = client.post("/v1/extract", json={"mode": "image", "schema": 1, "payload": "AAAA"}, headers=_h(a["access"]))
    assert r.status_code == 502
    # 截断有**自己的码**:客户端对两者的处置一样(重试一次,不成退回正则),但
    # 「模型把预算烧光了」和「上游宕机」的修法完全不同,日志里得分得开。
    assert r.json()["detail"] == "upstream_truncated"
    # 同一份内容,没被截断 → 照常 200。
    monkeypatch.setattr(extract, "_call_deepseek", lambda arm, model, messages: {
        "choices": [{"finish_reason": "stop", "message": {"content": '{"doc_type":"lab","labs":[]}'}}],
        "usage": {},
    })
    assert client.post("/v1/extract", json={"mode": "image", "schema": 1, "payload": "AAAA"}, headers=_h(a["access"])).status_code == 200


def test_extract_proxies_and_counts_tokens(monkeypatch):
    import extract
    monkeypatch.setattr(extract, "_call_deepseek", lambda arm, model, messages: {"choices": [{"message": {"content": '{"doc_type":"lab","labs":[]}'}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}})
    a = login("13800000060", "a")
    r = client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "血红蛋白 130 g/L", "hints": {}}, headers=_h(a["access"]))
    assert r.status_code == 200 and r.json()["doc_type"] == "lab"
    with dbm.connect() as conn:
        assert conn.execute("SELECT llm_tokens_in, llm_tokens_out FROM usage WHERE account_id=%s", (a["account_id"],)).fetchone() == (10, 5)
    os.environ["MEDME_EXTRACT_TOKEN"] = "dev-token"
    assert client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "x"}, headers={"Authorization": "Bearer dev-token"}).status_code == 200


def test_extract_response_carries_the_model_actually_used(monkeypatch):
    """客户端要把模型版本连同抽取结果一起落进保险箱(溯源)。模型名只有服务端知道
    (环境变量,运维随时能换),所以必须回在响应里 —— 客户端硬编码一个默认值就是
    在溯源上说谎。文本档和图片档各走一个环境变量,两条都要回对。"""
    import extract
    monkeypatch.setattr(extract, "MODEL_TEXT", "deepseek-text-x")
    monkeypatch.setattr(extract, "MODEL_VISION", "deepseek-vision-y")
    monkeypatch.setattr(extract, "_call_deepseek", lambda arm, model, messages: {
        "choices": [{"message": {"content": '{"doc_type":"lab","labs":[]}'}}], "usage": {}})
    a = login("13800000061", "a")
    h = _h(a["access"])
    assert client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "x"}, headers=h).json()["model"] == "deepseek-text-x"
    assert client.post("/v1/extract", json={"mode": "image", "schema": 1, "payload": "AAAA"}, headers=h).json()["model"] == "deepseek-vision-y"


def test_extract_dev_token_scoped_cannot_touch_profiles():
    os.environ["MEDME_EXTRACT_TOKEN"] = "dev-token-scope"
    hdev = {"Authorization": "Bearer dev-token-scope"}
    assert client.get("/v1/profiles", headers=hdev).status_code == 401
    r = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=hdev)
    assert r.status_code == 401
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM profiles").fetchone()[0] == 0


# ---- fix round 1 (Task 6 review) ----

def test_object_sign_rejects_bad_verb_before_role_check():
    a = login("13800000070", "a")
    v = login("13800000071", "v")
    ha, hv = _h(a["access"]), _h(v["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    token = "D" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 15, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
                                                            "wrapped_key_by_token": b64(b"w"), "invite_ttl_s": 600}, headers=ha).json()
    client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hv)
    oid = "ef" * 32
    r = client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": oid, "verb": "DELETE", "size": 1}, headers=hv)
    assert r.status_code == 400
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM objects WHERE profile_id=%s AND object_id=%s", (pid, oid)).fetchone()[0] == 0
        assert conn.execute("SELECT storage_bytes FROM usage WHERE account_id=%s", (v["account_id"],)).fetchone() is None
    assert client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": oid, "verb": "PUT", "size": 1}, headers=hv).status_code == 403


def test_object_sign_rejects_bad_size():
    a = login("13800000072", "a")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    oid1 = "11" * 32
    assert client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": oid1, "verb": "PUT", "size": -5000000000}, headers=ha).status_code == 400
    oid2 = "22" * 32
    oversize = app_module.OBJECT_MAX_BYTES + 1
    assert client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": oid2, "verb": "PUT", "size": oversize}, headers=ha).status_code == 400
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM objects WHERE profile_id=%s", (pid,)).fetchone()[0] == 0
        assert conn.execute("SELECT storage_bytes FROM usage WHERE account_id=%s", (a["account_id"],)).fetchone() is None


def test_object_sign_object_id_rejects_trailing_newline():
    a = login("13800000073", "a")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    r = client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": "ab" * 32 + "\n", "verb": "PUT", "size": 1}, headers=ha)
    assert r.status_code == 400


def test_object_sign_get_has_empty_content_type():
    os.environ.update({"OSS_ACCESS_KEY_ID": "AK", "OSS_ACCESS_KEY_SECRET": "SK", "OSS_BUCKET": "medme-vault", "OSS_ENDPOINT": "oss-cn-hangzhou.aliyuncs.com"})
    a = login("13800000074", "a")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    r = client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": "33" * 32, "verb": "GET"}, headers=ha)
    assert r.status_code == 200 and r.json()["content_type"] == ""


def test_events_push_rejects_malformed_events_all_or_nothing():
    a = login("13800000075", "a")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    good_id = eid("good")

    bad_seq = [{"device_id": "a", "seq": "NaN", "event_id": good_id, "ts": "2026-09-11T00:00:00Z", "ciphertext": b64(b"x")}]
    r = client.post(f"/v1/profiles/{pid}/events", json=bad_seq, headers=ha)
    assert r.status_code == 400 and r.json()["detail"] == "event 0: seq"

    missing_seq = [{"device_id": "a", "event_id": good_id, "ts": "2026-09-11T00:00:00Z", "ciphertext": b64(b"x")}]
    assert client.post(f"/v1/profiles/{pid}/events", json=missing_seq, headers=ha).status_code == 400

    bad_b64 = [{"device_id": "a", "seq": 1, "event_id": good_id, "ts": "2026-09-11T00:00:00Z", "ciphertext": "not-base64!!"}]
    assert client.post(f"/v1/profiles/{pid}/events", json=bad_b64, headers=ha).status_code == 400

    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM events WHERE profile_id=%s", (pid,)).fetchone()[0] == 0


def test_events_push_rejects_more_than_max_per_push():
    a = login("13800000076", "a")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    too_many = [{"device_id": "a", "seq": i, "event_id": eid(f"m{i}"), "ts": "2026-09-11T00:00:00Z", "ciphertext": b64(b"x")}
                for i in range(dbm.MAX_EVENTS_PER_PUSH + 1)]
    assert client.post(f"/v1/profiles/{pid}/events", json=too_many, headers=ha).status_code == 400
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM events WHERE profile_id=%s", (pid,)).fetchone()[0] == 0


def test_events_pull_rejects_malformed_since():
    a = login("13800000077", "a")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    assert client.get(f"/v1/profiles/{pid}/events", params={"since": "oops"}, headers=ha).status_code == 400
    assert client.get(f"/v1/profiles/{pid}/events", params={"since": json.dumps([1, 2])}, headers=ha).status_code == 400


def test_extract_upstream_garbage_is_502_not_400(monkeypatch):
    import extract
    monkeypatch.setattr(extract, "_call_deepseek", lambda arm, model, messages: {
        "choices": [{"message": {"content": "not json at all"}}], "usage": {"prompt_tokens": 1, "completion_tokens": 1}})
    a = login("13800000078", "a")
    r = client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "x"}, headers=_h(a["access"]))
    assert r.status_code == 502
    assert "not json" not in r.text
    # 不是截断,所以走的是通用码 —— 两个码别混。
    assert r.json()["detail"] == "upstream"


# ---- Task 15: 自助注销账号(DELETE /v1/account) ----

def test_account_delete_requires_reauth_401_and_nothing_changes():
    a = login("13800000120", "a1")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    # login() 内部的 otp_check 一成功就把那条 otp 行删了,这里没再发新验证码——
    # 随便给个 code 都应该 401,而不是悄悄通过。
    r = client.request("DELETE", "/v1/account", json={"phone": "13800000120", "otp_code": "999999"}, headers=ha)
    assert r.status_code == 401
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM accounts WHERE id=%s", (a["account_id"],)).fetchone()[0] == 1
        assert conn.execute("SELECT count(*) FROM profiles WHERE id=%s", (pid,)).fetchone()[0] == 1


def test_account_delete_happy_path_deletes_owned_profile_grants_and_oss(monkeypatch):
    os.environ.update({"OSS_ACCESS_KEY_ID": "AK", "OSS_ACCESS_KEY_SECRET": "SK", "OSS_BUCKET": "medme-vault", "OSS_ENDPOINT": "oss-cn-hangzhou.aliyuncs.com"})
    deleted_keys = []
    monkeypatch.setattr(oss, "delete_object", lambda key: deleted_keys.append(key) or True)

    owner = login("13800000121", "o1")
    other = login("13800000122", "x1")
    ho, hx = _h(owner["access"]), _h(other["access"])

    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    oid = "aa" * 32
    assert client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": oid, "verb": "PUT", "size": 10}, headers=ho).status_code == 200

    # other 的档案分享给 owner(viewer)——owner 注销后这份"别人拥有"的档案必须原样还在,
    # 只删 owner 作为 grantee 的那一行 grant。
    other_pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk2")}, headers=hx).json()["profile_id"]
    assert client.post(f"/v1/profiles/{other_pid}/grants", json={"grantee_account_id": owner["account_id"], "role": "viewer",
        "days": None, "wrapped_profile_key": b64(b"wk-shared")}, headers=hx).status_code == 200

    assert client.post("/v1/auth/otp", json={"phone": "13800000121"}).status_code == 200
    r = client.request("DELETE", "/v1/account", json={"phone": "13800000121", "otp_code": "000000"}, headers=ho)
    assert r.status_code == 204, r.text
    assert deleted_keys == [f"v/{pid}/{oid}"]
    assert r.headers["x-oss-deleted"] == "1/1"

    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM accounts WHERE id=%s", (owner["account_id"],)).fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM profiles WHERE id=%s", (pid,)).fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM objects WHERE profile_id=%s", (pid,)).fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM grants WHERE profile_id=%s", (pid,)).fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM devices WHERE account_id=%s", (owner["account_id"],)).fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM usage WHERE account_id=%s", (owner["account_id"],)).fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM otp WHERE phone_hash=%s", (f"lookup:{owner['account_id']}",)).fetchone()[0] == 0
        # grantee-only 关系被删,但那份档案本身(属于 other,不属于 owner)原样还在
        assert conn.execute(
            "SELECT count(*) FROM grants WHERE profile_id=%s AND grantee_id=%s", (other_pid, owner["account_id"])
        ).fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM profiles WHERE id=%s", (other_pid,)).fetchone()[0] == 1
        assert conn.execute("SELECT count(*) FROM accounts WHERE id=%s", (other["account_id"],)).fetchone()[0] == 1


# ---- fix round 1 (Task 15 review): item I1 —— OSS 删除失败(含缺环境变量的
# KeyError)不该在 DB 已提交之后把整个请求炸成 500;账号已经没了,500 只会让
# 客户端误以为注销失败、可能重试出一堆麻烦。 ----

def test_account_delete_oss_failure_after_commit_still_returns_204(monkeypatch):
    os.environ.update({"OSS_ACCESS_KEY_ID": "AK", "OSS_ACCESS_KEY_SECRET": "SK", "OSS_BUCKET": "medme-vault", "OSS_ENDPOINT": "oss-cn-hangzhou.aliyuncs.com"})

    def _boom(key):
        raise KeyError("OSS_ACCESS_KEY_ID")  # 模拟环境变量缺失/网络库炸出任意异常

    monkeypatch.setattr(oss, "delete_object", _boom)

    owner = login("13800000123", "o1")
    ho = _h(owner["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ho).json()["profile_id"]
    oid = "bb" * 32
    assert client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": oid, "verb": "PUT", "size": 10}, headers=ho).status_code == 200

    assert client.post("/v1/auth/otp", json={"phone": "13800000123"}).status_code == 200
    r = client.request("DELETE", "/v1/account", json={"phone": "13800000123", "otp_code": "000000"}, headers=ho)
    assert r.status_code == 204, r.text
    assert r.headers["x-oss-deleted"] == "0/1"

    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM accounts WHERE id=%s", (owner["account_id"],)).fetchone()[0] == 0


def test_account_delete_apple_requires_fresh_identity_token(monkeypatch):
    monkeypatch.setattr(oss, "delete_object", lambda key: True)
    from cryptography.hazmat.primitives.asymmetric import rsa

    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    kid = "test-kid-delete"

    def _token(sub):
        payload = {"iss": "https://appleid.apple.com", "aud": os.environ["APPLE_BUNDLE_ID"], "exp": int(time.time()) + 3600, "sub": sub}
        return jwt.encode(payload, private_key, algorithm="RS256", headers={"kid": kid})

    _install_fake_apple_jwks(private_key.public_key(), kid)
    r = client.post("/v1/auth/apple", json={"identity_token": _token("apple-delete-1"), "device_id": "d", "device_name": "d"})
    assert r.status_code == 200, r.text
    acc = r.json()
    h = _h(acc["access"])

    assert client.request("DELETE", "/v1/account", json={}, headers=h).status_code == 401
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM accounts WHERE id=%s", (acc["account_id"],)).fetchone()[0] == 1

    _install_fake_apple_jwks(private_key.public_key(), kid)  # JWKS 缓存 60 分钟内不过期,重装一下保险
    r = client.request("DELETE", "/v1/account", json={"identity_token": _token("apple-delete-1")}, headers=h)
    assert r.status_code == 204, r.text
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM accounts WHERE id=%s", (acc["account_id"],)).fetchone()[0] == 0


# ---- 最终评审修复波 ----

def test_account_delete_via_post_same_handler():
    """I5:App 走 `POST /v1/account/delete`(带 body 的 DELETE 会被网关丢 body),
    两条路由同一个 handler——重新鉴权、删除、204 行为必须一模一样。"""
    a = login("13800000130", "p1")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]

    # 先证明它和 DELETE 一样会要求重新鉴权
    assert client.post("/v1/account/delete", json={"phone": "13800000130", "otp_code": "999999"}, headers=ha).status_code == 401
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM accounts WHERE id=%s", (a["account_id"],)).fetchone()[0] == 1

    assert client.post("/v1/auth/otp", json={"phone": "13800000130"}).status_code == 200
    r = client.post("/v1/account/delete", json={"phone": "13800000130", "otp_code": "000000"}, headers=ha)
    assert r.status_code == 204, r.text
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM accounts WHERE id=%s", (a["account_id"],)).fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM profiles WHERE id=%s", (pid,)).fetchone()[0] == 0


def test_keys_put_only_once_409_and_row_unchanged():
    """M1:公钥只能设一次——第二次 409,且库里那一行一个字节都不许变(覆盖公钥
    = 所有已封的档案密钥全部解不开)。"""
    a = login("13800000131", "k1")
    ha = _h(a["access"])
    keys = {"public_key": b64(b"A" * 32), "wrapped_priv_pw": b64(b"pw"), "wrapped_priv_rc": b64(b"rc"),
            "kdf_salt": b64(b"s" * 16), "kdf_params": {"m_kib": 65536, "t": 3, "p": 1}}
    assert client.put("/v1/account/keys", json=keys, headers=ha).status_code == 200

    r = client.put("/v1/account/keys", json={**keys, "public_key": b64(b"B" * 32), "wrapped_priv_pw": b64(b"pw2")}, headers=ha)
    assert r.status_code == 409, r.text
    got = client.get("/v1/account/keys", headers=ha).json()
    assert got["public_key"] == keys["public_key"] and got["wrapped_priv_pw"] == keys["wrapped_priv_pw"]


def test_keys_put_missing_field_is_400_not_500():
    a = login("13800000132", "k2")
    assert client.put("/v1/account/keys", json={"public_key": b64(b"A" * 32)}, headers=_h(a["access"])).status_code == 400


def test_missing_body_fields_are_400_not_500():
    """M3:原来这些地方直接 `body["x"]`,少一个字段就是 KeyError → 500。
    两条代表性路由:建档案(最简路径)+ 批准设备(两个必填字段);顺带授权/邀请。"""
    a = login("13800000133", "m1")
    ha = _h(a["access"], "m1")
    assert client.post("/v1/profiles", json={}, headers=ha).status_code == 400
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM profiles").fetchone()[0] == 0

    assert client.post("/v1/devices/approve", json={"device_id": "m1"}, headers=ha).status_code == 400
    assert client.post("/v1/devices/request", json={}, headers=ha).status_code == 400
    # 授权/邀请也一样(role 合法但缺密钥字段 → 400,不是 500)
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    assert client.post(f"/v1/profiles/{pid}/grants", json={"role": "editor"}, headers=ha).status_code == 400
    assert client.post(f"/v1/profiles/{pid}/invites", json={"role": "nonsense", "token_hash": "x", "wrapped_key_by_token": b64(b"w")}, headers=ha).status_code == 400


def test_events_push_accepts_constant_ts():
    """I4:客户端不再明文发事件时间戳,统一发 "0"——服务端照收,排序只看
    (device_id, seq)。"""
    a = login("13800000134", "t1")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    evs = [{"device_id": "d1", "seq": 2, "event_id": eid("e2"), "ts": "0", "ciphertext": b64(b"c2")},
           {"device_id": "d1", "seq": 1, "event_id": eid("e1"), "ts": "0", "ciphertext": b64(b"c1")}]
    assert client.post(f"/v1/profiles/{pid}/events", json=evs, headers=ha).status_code == 200
    got = client.get(f"/v1/profiles/{pid}/events", headers=ha).json()
    assert [e["seq"] for e in got] == [1, 2], "排序不受 ts 影响"
    assert {e["ts"] for e in got} == {"0"}
    assert dbm.validate_event({"device_id": "d1", "seq": 1, "event_id": eid("e1"), "ts": "0", "ciphertext": b64(b"c")}) is None
    assert dbm.validate_event({"device_id": "d1", "seq": 1, "event_id": eid("e1"), "ts": "", "ciphertext": b64(b"c")}) == "ts"


def test_extract_rejects_oversize_payloads_413(monkeypatch):
    """I7:体积上限——超了就 413,连上游都不打(假上游一旦被调到 calls 就非空)。"""
    import extract
    calls = []
    monkeypatch.setattr(extract, "_call_deepseek", lambda arm, model, messages: calls.append(model) or {
        "choices": [{"message": {"content": "{}"}}], "usage": {}})
    a = login("13800000135", "x1")
    ha = _h(a["access"])
    big_text = "血" * (app_module.EXTRACT_TEXT_MAX_BYTES // 3 + 1)  # 每个汉字 3 字节
    assert client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": big_text}, headers=ha).status_code == 413
    big_img = "A" * (app_module.EXTRACT_IMAGE_MAX_BYTES + 1)
    assert client.post("/v1/extract", json={"mode": "image", "schema": 1, "payload": big_img}, headers=ha).status_code == 413
    assert calls == [], "超限请求不该打到上游"
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM usage WHERE account_id=%s", (a["account_id"],)).fetchone()[0] == 0
    # 刚好在上限之内的文本照常放行
    assert client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "x" * app_module.EXTRACT_TEXT_MAX_BYTES}, headers=ha).status_code == 200


def test_extract_rejects_non_str_payload_400(monkeypatch):
    """size 上限只在 `isinstance(payload, str)` 时才生效(app.py ~426)——payload
    不是 str(dict/list/int/None)时那段体积检查整个被跳过,请求会带着一个没被
    量过体积的东西继续往下走。必须在做任何事之前先拒收非 str payload。"""
    import extract
    calls = []
    monkeypatch.setattr(extract, "_call_deepseek", lambda arm, model, messages: calls.append(model) or {
        "choices": [{"message": {"content": "{}"}}], "usage": {}})
    a = login("13800000138", "x4")
    ha = _h(a["access"])
    for bad_payload in [{"a": "b"}, ["x"], 123, None]:
        r = client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": bad_payload}, headers=ha)
        assert r.status_code == 400, bad_payload
    assert calls == [], "非法 payload 不该打到上游"
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM usage WHERE account_id=%s", (a["account_id"],)).fetchone()[0] == 0


def test_extract_monthly_token_cap_429(monkeypatch):
    """I7:月度 token 天花板——已用量到顶就 429,不再打上游;按账号算,不是全局。"""
    import extract
    calls = []
    monkeypatch.setattr(extract, "_call_deepseek", lambda arm, model, messages: calls.append(model) or {
        "choices": [{"message": {"content": '{"doc_type":"lab"}'}}], "usage": {"prompt_tokens": 7, "completion_tokens": 3}})
    monkeypatch.setattr(app_module, "EXTRACT_MONTHLY_TOKEN_CAP", 10)
    a = login("13800000136", "x2")
    ha = _h(a["access"])

    # 第一次:本月用量 0 < 10,放行,用掉 7+3=10
    assert client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "x"}, headers=ha).status_code == 200
    with dbm.connect() as conn:
        assert conn.execute("SELECT llm_tokens_in + llm_tokens_out FROM usage WHERE account_id=%s", (a["account_id"],)).fetchone()[0] == 10
    # 第二次:已用 10 >= 10,429,不打上游
    calls.clear()
    assert client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "x"}, headers=ha).status_code == 429
    assert calls == []
    b = login("13800000137", "x3")
    assert client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "x"}, headers=_h(b["access"])).status_code == 200


# --- /v1/skills:无鉴权的公开静态包分发(disease-profile spec §8)-------------

def test_skills_index_needs_no_auth_and_is_a_signed_envelope():
    r = client.get("/v1/skills/index.json")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/json")
    env = r.json()
    # 路由只管原样发字节;验签是客户端的事。这里只钉住形状没退回裸清单。
    assert set(env) == {"sig", "package"}
    assert isinstance(json.loads(env["package"])["skills"], list)
    assert r.headers.get("etag")


def test_skills_index_honours_if_none_match():
    first = client.get("/v1/skills/index.json")
    etag = first.headers["etag"]
    again = client.get("/v1/skills/index.json", headers={"If-None-Match": etag})
    assert again.status_code == 304
    assert again.content == b""


def test_skills_route_never_reads_the_authorization_header():
    # 带一个**错的** bearer 也必须照样 200:这条路由不认账号,也就不可能把
    # 「你开启了哪个病」和账号关联起来(spec §8 的隐私前提)。
    r = client.get("/v1/skills/index.json", headers={"Authorization": "Bearer not-a-real-token"})
    assert r.status_code == 200


def test_skills_package_path_traversal_is_rejected():
    # id / version 都会拼进文件路径,是信任边界。放行任何 . 或 / 都是任意文件读。
    for sid, ver in [("..", "x"), ("sle", ".."), ("a/b", "x"), ("sle", "../../app")]:
        r = client.get(f"/v1/skills/{sid}/{ver}.json")
        assert r.status_code in (400, 404), f"{sid}/{ver} 竟然是 {r.status_code}"


def test_skills_unknown_package_is_404():
    assert client.get("/v1/skills/nosuchdisease/2026.09.1.json").status_code == 404


def test_skills_package_is_served_verbatim_when_present(tmp_path):
    import app as app_mod

    root = tmp_path / "skills"
    (root / "demo").mkdir(parents=True)
    body = '{"sig":"AA","package":"{}"}'
    (root / "demo" / "2026.09.1.json").write_text(body, encoding="utf-8")
    old = app_mod.SKILLS_DIR
    app_mod.SKILLS_DIR = root
    try:
        r = client.get("/v1/skills/demo/2026.09.1.json")
        assert r.status_code == 200
        assert r.text == body  # 逐字节原样,签名才验得过
        assert r.headers.get("etag")
    finally:
        app_mod.SKILLS_DIR = old


if __name__ == "__main__":
    # `python3 services/api/test_api.py`:与 services/claim-signer/test_handler.py 同风格的
    # 无 pytest 自检——手动跑每个 test_* 函数,复用 `clean` fixture 的清库逻辑,
    # 任意一个失败就非零退出。
    import sys as _sys

    if not DB:
        print("跳过:没有 DATABASE_URL")
        _sys.exit(0)

    def _clean_db():
        with dbm.connect() as conn:
            dbm.ensure_schema(conn)
            conn.execute(
                "TRUNCATE accounts, devices, profiles, grants, invites, events, objects, usage, otp CASCADE"
            )
            conn.commit()

    import inspect as _inspect

    _tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    _fail = []
    for _t in _tests:
        _clean_db()
        # 少数测试要 monkeypatch 一个 pytest fixture 参数(如 test_extract_* 打桩
        # _call_deepseek,免得自检真打 DeepSeek 的网)——pytest.MonkeyPatch 本身是
        # 独立于 fixture 系统可以直接实例化的公开 API,不用起一整个 pytest session。
        _mp = pytest.MonkeyPatch() if "monkeypatch" in _inspect.signature(_t).parameters else None
        try:
            _t(_mp) if _mp else _t()
            print(f"  ✓ {_t.__name__}")
        except Exception as e:  # noqa: BLE001 - 自检要能报出任何一种失败
            print(f"  ✗ {_t.__name__}  {e!r}")
            _fail.append(_t.__name__)
        finally:
            if _mp:
                _mp.undo()

    print()
    if _fail:
        print(f"❌ {len(_fail)} 项未通过:{_fail}")
        _sys.exit(1)
    print("✅ 全部通过")
