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

from fastapi.testclient import TestClient  # noqa: E402
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
