"""MedMe 账号/同步/授权/LLM 代理 API。阿里云 FC 自定义运行时:`python3 -m uvicorn app:app --host 0.0.0.0 --port 9000`。
服务端只见密文:此文件里不得出现任何解密调用。"""
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
