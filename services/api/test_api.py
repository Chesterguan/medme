"""后端测试。对本机 PostgreSQL 跑:
    DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest services/api -q
库不存在先 `createdb -p 5435 medme_api_test`。没有 DATABASE_URL 时整文件跳过。
"""
import base64, hashlib, json, os, time
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
    lk = client.get("/v1/accounts/lookup", params={"phone": "13800000011"}, headers=ha).json()
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


# ---- fix round 1: item 4 —— /v1/accounts/lookup 要走 normalize_phone,且限流 ----

def test_accounts_lookup_normalizes_plus86_and_rate_limits():
    alice = login("13800000099", "a1")
    bob = login("13800000100", "b1")
    ha = _h(alice["access"])
    keys = {"public_key": b64(b"K" * 32), "wrapped_priv_pw": b64(b"pw"), "wrapped_priv_rc": b64(b"rc"),
            "kdf_salt": b64(b"s" * 16), "kdf_params": {"m_kib": 65536, "t": 3, "p": 1}}
    client.put("/v1/account/keys", json=keys, headers=_h(bob["access"]))
    r = client.get("/v1/accounts/lookup", params={"phone": "+8613800000100"}, headers=ha)
    assert r.status_code == 200 and r.json()["account_id"] == bob["account_id"]
    for _ in range(19):
        assert client.get("/v1/accounts/lookup", params={"phone": "13800000100"}, headers=ha).status_code == 200
    assert client.get("/v1/accounts/lookup", params={"phone": "13800000100"}, headers=ha).status_code == 429


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
    evs = [{"device_id": "a", "seq": i, "event_id": f"e{i}", "ts": "2026-09-11T00:00:00Z", "ciphertext": b64(b"c%d" % i)} for i in (1, 2, 3)]
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
    ev = [{"device_id": "v", "seq": 1, "event_id": "ev1", "ts": "2026-09-11T00:00:00Z", "ciphertext": b64(b"x")}]
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


def test_extract_proxies_and_counts_tokens(monkeypatch):
    import extract
    monkeypatch.setattr(extract, "_call_deepseek", lambda model, messages: {"choices": [{"message": {"content": '{"doc_type":"lab","labs":[]}'}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}})
    a = login("13800000060", "a")
    r = client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "血红蛋白 130 g/L", "hints": {}}, headers=_h(a["access"]))
    assert r.status_code == 200 and r.json()["doc_type"] == "lab"
    with dbm.connect() as conn:
        assert conn.execute("SELECT llm_tokens_in, llm_tokens_out FROM usage WHERE account_id=%s", (a["account_id"],)).fetchone() == (10, 5)
    os.environ["MEDME_EXTRACT_TOKEN"] = "dev-token"
    assert client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "x"}, headers={"Authorization": "Bearer dev-token"}).status_code == 200


def test_extract_dev_token_scoped_cannot_touch_profiles():
    os.environ["MEDME_EXTRACT_TOKEN"] = "dev-token-scope"
    hdev = {"Authorization": "Bearer dev-token-scope"}
    assert client.get("/v1/profiles", headers=hdev).status_code == 401
    r = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=hdev)
    assert r.status_code == 401
    with dbm.connect() as conn:
        assert conn.execute("SELECT count(*) FROM profiles").fetchone()[0] == 0


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
