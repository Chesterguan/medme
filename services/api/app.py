"""MedMe 账号/同步/授权/LLM 代理 API。阿里云 FC 自定义运行时:`python3 -m uvicorn app:app --host 0.0.0.0 --port 9000`。
服务端只见密文:此文件里不得出现任何解密调用。"""
import datetime
import os
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
import auth, db

app = FastAPI(title="medme-api")


@app.on_event("startup")
def _startup():
    with db.connect() as conn:
        db.ensure_schema(conn)


def conn_dep():
    conn = db.connect()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def account_dep(authorization: str = Header(default="")) -> str:
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer")
    token = authorization[7:]
    # 子项目 A 评测期的静态 token(与 claim-signer 的 MEDME_UPLOAD_TOKEN 同一模式)
    dev = os.environ.get("MEDME_EXTRACT_TOKEN", "")
    if dev and token == dev:
        return "dev"
    try:
        return auth.verify_access(token)
    except auth.AuthError as e:
        raise HTTPException(401, str(e))


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/v1/auth/otp")
def auth_otp(body: dict, conn=Depends(conn_dep)):
    if not isinstance(body, dict):
        raise HTTPException(400, "bad request")
    try:
        # 手机号在信任边界(哈希/发短信之前)就要校验,别让格式错误或非字符串
        # 值一路传到 phone_hash() 里炸出 500。
        phone = auth.normalize_phone(body.get("phone"))
    except auth.AuthError:
        raise HTTPException(400, "bad phone")
    try:
        auth.otp_send(conn, phone)
    except auth.AuthError:
        raise HTTPException(429, "rate_limited")
    return {"ok": True}


def _login_with(provider: str, body: dict, conn):
    if not isinstance(body, dict):
        raise HTTPException(400, "bad request")
    if provider == "otp":
        try:
            body = {**body, "phone": auth.normalize_phone(body.get("phone"))}
        except auth.AuthError:
            raise HTTPException(400, "bad phone")
    try:
        aid = auth.PROVIDERS[provider].login(conn, body)
    except NotImplementedError:
        raise HTTPException(501, "not implemented")
    except auth.AuthError as e:
        raise HTTPException(401, str(e))
    db.device_touch(conn, aid, body.get("device_id", ""), body.get("device_name", ""))
    return {"account_id": aid, **auth.issue_tokens(aid)}


@app.post("/v1/auth/login")
def auth_login(body: dict, conn=Depends(conn_dep)):
    return _login_with("otp", body, conn)


@app.post("/v1/auth/apple")
def auth_apple(body: dict, conn=Depends(conn_dep)):
    return _login_with("apple", body, conn)


@app.post("/v1/auth/wechat")
def auth_wechat(body: dict, conn=Depends(conn_dep)):
    return _login_with("wechat", body, conn)


@app.post("/v1/auth/refresh")
def auth_refresh(body: dict):
    try:
        aid = auth.verify_refresh(body.get("refresh", ""))
    except auth.AuthError as e:
        raise HTTPException(401, str(e))
    return auth.issue_tokens(aid)


def _require_role(conn, pid, aid, allowed):
    role = db.role_for(conn, pid, aid)
    if role not in allowed:
        raise HTTPException(403, "forbidden")
    return role


@app.put("/v1/account/keys")
def keys_put(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    db.keys_put(conn, aid, body)
    return {"ok": True}


@app.get("/v1/account/keys")
def keys_get(aid=Depends(account_dep), conn=Depends(conn_dep)):
    k = db.keys_get(conn, aid)
    if not k:
        raise HTTPException(404, "no keys")
    return k


@app.get("/v1/accounts/lookup")
def account_lookup(phone: str, aid=Depends(account_dep), conn=Depends(conn_dep)):
    r = db.account_lookup_by_phone_hash(conn, auth.phone_hash(phone))
    if not r:
        raise HTTPException(404, "not found")
    return r


@app.post("/v1/profiles")
def profile_create(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    return {"profile_id": db.profile_create(conn, aid, body["wrapped_profile_key"])}


@app.get("/v1/profiles")
def profiles_list(aid=Depends(account_dep), conn=Depends(conn_dep)):
    return db.profiles_for(conn, aid)


@app.post("/v1/profiles/{pid}/grants")
def grant_create(pid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner"})
    if body["role"] not in ("editor", "viewer"):
        raise HTTPException(400, "role")
    days = body.get("days")
    exp = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)) if days else None
    gid = db.grant_upsert(conn, pid, body["grantee_account_id"], body["role"], exp, db.b64d(body["wrapped_profile_key"]), aid)
    return {"grant_id": gid}


@app.delete("/v1/profiles/{pid}/grants/{gid}")
def grant_delete(pid: str, gid: str, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner"})
    db.grant_delete(conn, pid, gid)
    return {"ok": True}


@app.put("/v1/profiles/{pid}/grants/{gid}/key")
def grant_set_key(pid: str, gid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner", "editor", "viewer"})
    db.grant_set_key(conn, pid, gid, aid, body["wrapped_profile_key"])
    return {"ok": True}


@app.post("/v1/profiles/{pid}/invites")
def invite_create(pid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner"})
    return {"invite_id": db.invite_create(conn, pid, aid, body)}


@app.post("/v1/invites/redeem")
def invite_redeem(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    status, payload = db.invite_redeem(conn, body.get("invite_id", ""), body.get("token", ""), aid)
    if status == "notfound":
        raise HTTPException(404, "not found")
    if status == "gone":
        raise HTTPException(410, "used or expired")
    return payload


@app.post("/v1/devices/request")
def device_request(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep), x_device_id: str = Header(default="")):
    db.device_request(conn, aid, body.get("device_id") or x_device_id, body["eph_public"])
    return {"ok": True}


@app.get("/v1/devices")
def devices_list(aid=Depends(account_dep), conn=Depends(conn_dep)):
    return db.devices_list(conn, aid)


@app.post("/v1/devices/approve")
def device_approve(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    db.device_approve(conn, aid, body["device_id"], body["approved_priv"])
    return {"ok": True}


@app.get("/v1/devices/approval")
def device_approval(device_id: str, aid=Depends(account_dep), conn=Depends(conn_dep)):
    return {"approved_priv": db.device_take_approval(conn, aid, device_id)}
