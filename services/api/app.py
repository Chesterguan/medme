"""MedMe 账号/同步/授权/LLM 代理 API。阿里云 FC 自定义运行时:`python3 -m uvicorn app:app --host 0.0.0.0 --port 9000`。
服务端只见密文:此文件里不得出现任何解密调用。"""
import datetime
import json
import os
import re
from typing import List
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import JSONResponse
import auth, db, extract, oss

_OID = re.compile(r"[0-9a-f]{64}")  # 用 .fullmatch() 校验;.match() + 结尾 $ 会放过一个尾随换行
_SIGN_VERBS = {"PUT", "GET"}
OBJECT_MAX_BYTES = 64 * 1024 * 1024  # 64 MiB:预签名对象的体积上限(OSS V1 预签名本身管不了体积,这里在登记前先挡一道)

# /v1/extract 的体积上限与月度 token 天花板(最终评审 I7:这条路由原来完全不计量,
# 一个拿到 token 的客户端可以无限烧 DeepSeek 的钱)。文本按 UTF-8 字节算,图片按
# base64 字符串本身的长度算(客户端传上来的就是这个)。
EXTRACT_TEXT_MAX_BYTES = 64 * 1024
EXTRACT_IMAGE_MAX_BYTES = 2 * 1024 * 1024
EXTRACT_MONTHLY_TOKEN_CAP = int(os.environ.get("EXTRACT_MONTHLY_TOKEN_CAP", 2_000_000))

app = FastAPI(title="medme-api")


def _req(body, *keys):
    """取必填字段——缺字段(或 body 压根不是 dict)一律 400。

    原来这些地方直接写 `body["x"]`:少一个字段就是 `KeyError` → 500,服务端日志里
    一条"内部错误",客户端拿到的也是 500(看上去像服务挂了,其实是请求畸形)。
    单个 key 返回值本身,多个 key 返回一个列表(按传入顺序解包)。"""
    if not isinstance(body, dict):
        raise HTTPException(400, "bad request")
    out = []
    for k in keys:
        v = body.get(k)
        if v is None:
            raise HTTPException(400, f"missing {k}")
        out.append(v)
    return out if len(keys) > 1 else out[0]


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
    try:
        return auth.verify_access(token)
    except auth.AuthError as e:
        raise HTTPException(401, str(e))


def extract_account_dep(authorization: str = Header(default="")) -> str:
    """只给 /v1/extract 用:多接受子项目 A 评测期的静态 token(与 claim-signer 的
    MEDME_UPLOAD_TOKEN 同一模式)。别的路由一律走 account_dep,拿这个 token 去调
    会在 auth.verify_access 里炸成 401——这就是"scope 到 extract"的全部实现。"""
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer")
    token = authorization[7:]
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
    """首次注册时落账号密钥。**只能设一次**(`db.keys_put` 带
    `WHERE public_key IS NULL`):覆盖一次公钥,等于把已经用旧公钥封过的档案密钥
    全部变成解不开的垃圾——客户端的阶段机本来走不到这儿(最终评审 M1),但这是
    一条不可逆的破坏,服务端必须自己挡住,不靠客户端自律。"""
    _req(body, "public_key", "wrapped_priv_pw", "wrapped_priv_rc", "kdf_salt", "kdf_params")
    if db.keys_put(conn, aid, body) == 0:
        raise HTTPException(409, "keys already set")
    return {"ok": True}


@app.get("/v1/account/keys")
def keys_get(aid=Depends(account_dep), conn=Depends(conn_dep)):
    k = db.keys_get(conn, aid)
    if not k:
        raise HTTPException(404, "no keys")
    return k


@app.post("/v1/account/delete", status_code=204)
@app.delete("/v1/account", status_code=204)
def account_delete(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    """自助注销(大陆 App Store 强制要求的自助渠道)。**必须重新证明"是本人"**——
    偷来的 access token 不该单独就能把账号删了:手机号账号要求 body 带一个刚发的
    OTP 验证码(`phone` + `otp_code`),Apple 账号要求带一个刚拿到的
    `identity_token`。任何一步核不过都是 401,不区分"账号不存在"/"验证码不对"
    (同 `account_dep` 的一贯做法,不给攻击者当存在性预言机)。
    实际删除见 `db.account_delete`(DB all-or-nothing,由 `conn_dep` 的
    提交/回滚兜底);OSS 对象在 DB 提交之后才最佳努力删,失败个数放进响应头,
    不影响这次注销本身是否成功——见 Task 15 brief 的设计约束。

    **两条路由同一个 handler**:`POST /v1/account/delete` 是 App 实际调的那条
    (最终评审 I5:带 body 的 DELETE 会被一些网关/代理把 body 丢掉,那样重新鉴权
    的凭证就永远"缺失" → 401);`DELETE /v1/account` 保留兼容,语义完全一致。"""
    if not isinstance(body, dict):
        raise HTTPException(400, "bad request")
    row = conn.execute("SELECT phone_hash, apple_sub FROM accounts WHERE id=%s", (aid,)).fetchone()
    if not row:
        raise HTTPException(404, "not found")
    phone_hash, apple_sub = row
    if phone_hash is not None:
        try:
            phone = auth.normalize_phone(body.get("phone"))
        except auth.AuthError:
            raise HTTPException(401, "reauth required")
        code = body.get("otp_code")
        if (
            not isinstance(code, str)
            or auth.phone_hash(phone) != phone_hash
            or not auth.otp_check(conn, phone, code)
        ):
            raise HTTPException(401, "reauth required")
    elif apple_sub is not None:
        try:
            sub = auth.apple_verify(body.get("identity_token") or "")
        except auth.AuthError:
            raise HTTPException(401, "reauth required")
        if sub != apple_sub:
            raise HTTPException(401, "reauth required")
    else:
        raise HTTPException(401, "reauth required")  # 没有任何登录方式的账号,理论上不该出现

    oss_keys = db.account_delete(conn, aid)
    conn.commit()  # DB 全部落盘之后才动 OSS——半途失败也不会把云端对象删了却还留着账号
    # fix round 1 (Task 15 review) item I1: 这一步无论如何都不能再让请求炸成
    # 500——账号这会儿已经没了,`oss.delete_object` 内部把已知异常都收了,但这里
    # 再兜一层(配错的环境变量、`urllib` 抛出没预料到的异常类型……),失败就当
    # 这一个没删成,继续删下一个,不中断、也不影响这次注销本身的返回值。
    deleted = 0
    for k in oss_keys:
        try:
            if oss.delete_object(k):
                deleted += 1
        except Exception:
            pass
    return Response(status_code=204, headers={"X-Oss-Deleted": f"{deleted}/{len(oss_keys)}"})


@app.post("/v1/accounts/lookup")
def account_lookup(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    """按手机号查账号(家属授权用)。**POST body 而不是 GET 查询串**——手机号是
    可辨识个人信息,查询串一路进 access log/代理日志/浏览器历史,POST body 不会。

    **两种"失败"必须分开说**(B4):
      · 404 `not found` —— 这个手机号压根没有账号;
      · 409 `no_keys` —— 注册过了,但还没走完「设置口令 + 抄恢复码」,所以没有
        账号公钥,没法把档案密钥封给他。

    在这之前两者都是 404,客户端只能说一句「没有找到使用该手机号的账号」——
    而最常见的真实情况正是第二种(父母装了 App、登录了、卡在设口令那一步),
    于是家属得到的是一句**错误归因**,他会去确认手机号、重输、放弃,而真正要做的
    事在对方手机上。存在性预言机本来就是这个端点接受并写进文档的行为(见
    `Grants.grantFamilyByPhone`),多这一档不构成新的泄露类别。"""
    if not isinstance(body, dict):
        raise HTTPException(400, "bad request")
    try:
        phone = auth.normalize_phone(body.get("phone"))
    except auth.AuthError:
        raise HTTPException(400, "bad phone")
    if not db.lookup_rate_ok(conn, aid):
        raise HTTPException(429, "rate_limited")
    r = db.account_lookup_by_phone_hash(conn, auth.phone_hash(phone))
    if not r:
        raise HTTPException(404, "not found")
    if r["public_key"] is None:
        raise HTTPException(409, "no_keys")
    return r


@app.post("/v1/profiles")
def profile_create(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    return {"profile_id": db.profile_create(conn, aid, _req(body, "wrapped_profile_key"))}


@app.get("/v1/profiles")
def profiles_list(aid=Depends(account_dep), conn=Depends(conn_dep)):
    return db.profiles_for(conn, aid)


@app.post("/v1/profiles/{pid}/grants")
def grant_create(pid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner"})
    role, grantee, wrapped = _req(body, "role", "grantee_account_id", "wrapped_profile_key")
    if role not in ("editor", "viewer"):
        raise HTTPException(400, "role")
    if grantee == aid:
        raise HTTPException(400, "cannot grant to self")
    days = body.get("days")
    if days:
        days = min(int(days), db.GRANT_DOCTOR_DAYS)
    exp = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)) if days else None
    gid = db.grant_upsert(conn, pid, grantee, role, exp, db.b64d(wrapped), aid)
    return {"grant_id": gid}


@app.get("/v1/profiles/{pid}/grants")
def grants_list(pid: str, aid=Depends(account_dep), conn=Depends(conn_dep)):
    """owner 查「我授权给谁」——只列 grant 的元数据(grant_id/grantee_kind/role/
    expires_at/created_at),**不带手机号/姓名**:服务端本来就不存这些(见
    `grants` 表 schema),这里只是显式重申一遍,不给将来加字段时手滑带出去
    留一个"看起来该有"的借口。"""
    _require_role(conn, pid, aid, {"owner"})
    return db.grants_list(conn, pid)


@app.delete("/v1/profiles/{pid}/grants/{gid}")
def grant_delete(pid: str, gid: str, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner"})
    if db.grant_delete(conn, pid, gid) == 0:
        raise HTTPException(404, "not found")
    return {"ok": True}


@app.put("/v1/profiles/{pid}/grants/{gid}/key")
def grant_set_key(pid: str, gid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner", "editor", "viewer"})
    if db.grant_set_key(conn, pid, gid, aid, _req(body, "wrapped_profile_key")) == 0:
        raise HTTPException(404, "not found")
    return {"ok": True}


@app.post("/v1/profiles/{pid}/invites")
def invite_create(pid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner"})
    role, _, _ = _req(body, "role", "token_hash", "wrapped_key_by_token")
    if role not in ("owner", "editor", "viewer"):
        raise HTTPException(400, "role")  # 不然落到 invites 表的 CHECK 约束上,炸成 500
    return {"invite_id": db.invite_create(conn, pid, aid, body)}


@app.post("/v1/invites/redeem")
def invite_redeem(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    status, payload = db.invite_redeem(conn, body.get("invite_id", ""), body.get("token", ""), aid)
    if status == "notfound":
        raise HTTPException(404, "not found")
    if status == "gone":
        raise HTTPException(410, "used or expired")
    if status == "self":
        raise HTTPException(400, "cannot redeem own invite")
    return payload


@app.post("/v1/devices/request")
def device_request(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep), x_device_id: str = Header(default="")):
    if db.device_request(conn, aid, body.get("device_id") or x_device_id, _req(body, "eph_public")) == 0:
        raise HTTPException(404, "device not found")
    return {"ok": True}


@app.get("/v1/devices")
def devices_list(aid=Depends(account_dep), conn=Depends(conn_dep)):
    return db.devices_list(conn, aid)


@app.post("/v1/devices/approve")
def device_approve(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep), x_device_id: str = Header(default="")):
    # 批准者必须是自己账号下一台已经可信的设备——挂起中(等批准/等取走)的设备
    # 不能批准任何设备,包括它自己。
    if not db.device_is_trusted(conn, aid, x_device_id):
        raise HTTPException(403, "approving device not trusted")
    did, approved_priv = _req(body, "device_id", "approved_priv")
    if db.device_approve(conn, aid, did, approved_priv) == 0:
        raise HTTPException(404, "device not found")
    return {"ok": True}


@app.get("/v1/devices/approval")
def device_approval(device_id: str, aid=Depends(account_dep), conn=Depends(conn_dep), x_device_id: str = Header(default="")):
    # 只能取自己那台设备的批准——查询参数必须等于调用者自报的 X-Device-Id,
    # 否则不查库、直接当作不存在,免得设备 A 靠猜 device_id 拿到设备 B 的密文。
    if not x_device_id or x_device_id != device_id:
        raise HTTPException(404, "not found")
    return {"approved_priv": db.device_take_approval(conn, aid, device_id)}


# ---- 事件推拉、对象预签名、LLM 代理(Task 6) ----

@app.get("/v1/profiles/{pid}/events")
def events_pull(pid: str, since: str = "{}", aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner", "editor", "viewer"})
    try:
        since_map = json.loads(since)
        if not isinstance(since_map, dict) or not all(
            isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool) for k, v in since_map.items()
        ):
            raise ValueError("since")
    except (ValueError, TypeError):
        raise HTTPException(400, "since")
    events, seq_map = db.events_pull(conn, pid, since_map)
    return JSONResponse(content=events, headers={"X-Seq-Map": json.dumps(seq_map)})


@app.post("/v1/profiles/{pid}/events")
def events_push(pid: str, body: List[dict], aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner", "editor"})
    if len(body) > db.MAX_EVENTS_PER_PUSH:
        raise HTTPException(400, "too many events")
    for i, e in enumerate(body):
        err = db.validate_event(e)
        if err:
            raise HTTPException(400, f"event {i}: {err}")
    db.events_push(conn, pid, body)
    return {"ok": True}


@app.post("/v1/profiles/{pid}/objects/sign")
def object_sign(pid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    verb = body.get("verb", "GET")
    oid = body.get("object_id", "")
    if verb not in _SIGN_VERBS:
        raise HTTPException(400, "verb")
    if not _OID.fullmatch(oid):
        raise HTTPException(400, "object_id")
    size = body.get("size", 0)
    if verb == "PUT" and (isinstance(size, bool) or not isinstance(size, int) or not (0 < size <= OBJECT_MAX_BYTES)):
        raise HTTPException(400, "size")
    _require_role(conn, pid, aid, {"owner", "editor"} if verb == "PUT" else {"owner", "editor", "viewer"})
    if verb == "PUT":
        db.object_register(conn, pid, aid, oid, size)
    return {"url": oss.presign(verb, f"v/{pid}/{oid}"),
            "content_type": oss.CONTENT_TYPE if verb == "PUT" else "", "expires_in": oss.PRESIGN_TTL}


@app.get("/v1/profiles/{pid}/objects")
def objects_list(pid: str, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner", "editor", "viewer"})
    return db.objects_list(conn, pid)


@app.post("/v1/extract")
def extract_route(body: dict, aid=Depends(extract_account_dep), conn=Depends(conn_dep)):
    """LLM 代理。**先计量,再放行**(最终评审 I7):
    ① 体积上限——文本 64 KiB、图片 2 MiB(base64 串本身),超了 413,不打上游;
    ② 月度 token 天花板——本月已用 in+out 超过 `EXTRACT_MONTHLY_TOKEN_CAP` 就 429。
    天花板是**事后**判定(这一次请求本身还是会超一点):要做到精确不超,得先预估
    这次要花多少 token,而那个数只有上游返回后才知道——宁可多花一次请求的量,也
    不引入一个猜出来的预估值。"""
    if not isinstance(body, dict):
        raise HTTPException(400, "bad request")
    payload = body.get("payload")
    if not isinstance(payload, str):
        raise HTTPException(400, "payload must be a string")
    if body.get("mode") == "image":
        if len(payload) > EXTRACT_IMAGE_MAX_BYTES:
            raise HTTPException(413, "payload too large")
    elif len(payload.encode()) > EXTRACT_TEXT_MAX_BYTES:
        raise HTTPException(413, "payload too large")
    if db.usage_tokens_this_month(conn, aid) >= EXTRACT_MONTHLY_TOKEN_CAP:
        raise HTTPException(429, "monthly token cap reached")
    try:
        result, tin, tout = extract.run(body)
    except extract.SchemaError as e:
        raise HTTPException(400, str(e))
    # 截断这条要排在前面:`TruncatedError` 是 `UpstreamError` 的子类。两者都回 502
    # (客户端处置一样:重试一次,不成退回正则),但 detail 不同 —— 「模型把预算
    # 烧光了」和「上游宕机」的修法完全不同,日志里得分得开。
    except extract.TruncatedError:
        raise HTTPException(502, "upstream_truncated")
    except extract.UpstreamError:  # 上游失败如实报 502,不回显上游内容(也不进日志)
        raise HTTPException(502, "upstream")
    db.usage_add(conn, aid, tokens_in=tin, tokens_out=tout)
    return result
