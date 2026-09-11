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

    _tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    _fail = []
    for _t in _tests:
        _clean_db()
        try:
            _t()
            print(f"  ✓ {_t.__name__}")
        except Exception as e:  # noqa: BLE001 - 自检要能报出任何一种失败
            print(f"  ✗ {_t.__name__}  {e!r}")
            _fail.append(_t.__name__)

    print()
    if _fail:
        print(f"❌ {len(_fail)} 项未通过:{_fail}")
        _sys.exit(1)
    print("✅ 全部通过")
