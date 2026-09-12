"""建表 + 全部查询。所有函数接收 psycopg.Connection;没有 ORM。
服务端只存密文与账号业务数据:任何列都不该出现明文病历、档案密钥、私钥、口令。"""
import base64
import binascii
import datetime
import hashlib
import hmac
import os
import re
import secrets
import time
import psycopg

SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY,
  phone_hash TEXT UNIQUE,
  apple_sub TEXT UNIQUE,
  wechat_openid TEXT UNIQUE,            -- 预留,v1 永远 NULL
  public_key BYTEA,                     -- X25519 公钥 32B
  wrapped_priv_pw BYTEA,                -- 口令 KEK 包的私钥
  wrapped_priv_rc BYTEA,                -- 恢复码 KEK 包的私钥
  kdf_salt BYTEA,
  kdf_params JSONB,                     -- {"m_kib":..,"t":..,"p":..}
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS devices (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  eph_public BYTEA,                     -- 等待批准时的临时公钥
  approved_priv BYTEA,                  -- 旧设备封给它的私钥(取走即删)
  approved_at TIMESTAMPTZ,              -- approved_priv 写入的时刻,配合 24h 清扫(见 sweep_stale_approvals)
  last_seen TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, device_id)
);
CREATE TABLE IF NOT EXISTS profiles (
  id TEXT PRIMARY KEY,
  owner_account_id TEXT NOT NULL REFERENCES accounts(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS grants (
  id TEXT PRIMARY KEY,
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  grantee_kind TEXT NOT NULL CHECK (grantee_kind IN ('account','org')),
  grantee_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner','editor','viewer')),
  expires_at TIMESTAMPTZ,
  wrapped_profile_key BYTEA,            -- 用 grantee 公钥封的档案密钥(邀请兑换后由 grantee 回填)
  created_by TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (profile_id, grantee_kind, grantee_id)
);
CREATE TABLE IF NOT EXISTS invites (
  id TEXT PRIMARY KEY,
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner','editor','viewer')),
  grant_days INT,                       -- NULL = 永久
  token_hash TEXT NOT NULL,
  wrapped_key_by_token BYTEA NOT NULL,  -- 用 token 派生 KEK 包的档案密钥
  expires_at TIMESTAMPTZ NOT NULL,      -- 邀请本身的有效期
  created_by TEXT NOT NULL,
  redeemed_by TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS events (
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  seq BIGINT NOT NULL,
  event_id TEXT NOT NULL,
  ts TEXT NOT NULL,
  ciphertext BYTEA NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (profile_id, device_id, seq)
);
CREATE TABLE IF NOT EXISTS objects (
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  object_id TEXT NOT NULL,
  size BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (profile_id, object_id)
);
CREATE TABLE IF NOT EXISTS usage (
  account_id TEXT NOT NULL,
  month TEXT NOT NULL,                  -- 'YYYY-MM'
  llm_tokens_in BIGINT NOT NULL DEFAULT 0,
  llm_tokens_out BIGINT NOT NULL DEFAULT 0,
  storage_bytes BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, month)
);
CREATE TABLE IF NOT EXISTS otp (
  phone_hash TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  attempts INT NOT NULL DEFAULT 0,
  sends_in_window INT NOT NULL DEFAULT 0,
  window_started TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


def connect():
    return psycopg.connect(os.environ["DATABASE_URL"])


def ensure_schema(conn):
    conn.execute(SCHEMA)
    # `CREATE TABLE IF NOT EXISTS` 不会给已存在的表补列——`devices.approved_at`
    # 是在 `devices` 表已经上线之后才加的(Task 16 item 4),老库要单独迁移一下。
    conn.execute("ALTER TABLE devices ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ")
    conn.commit()


def new_id(prefix):
    return f"{prefix}_{secrets.token_urlsafe(12)}"


def account_by_phone_hash(conn, h):
    return conn.execute("SELECT id FROM accounts WHERE phone_hash=%s", (h,)).fetchone()


def account_by_apple_sub(conn, sub):
    return conn.execute("SELECT id FROM accounts WHERE apple_sub=%s", (sub,)).fetchone()


def account_create(conn, *, phone_hash=None, apple_sub=None):
    aid = new_id("acc")
    conn.execute("INSERT INTO accounts(id, phone_hash, apple_sub) VALUES (%s,%s,%s)", (aid, phone_hash, apple_sub))
    return aid


def device_touch(conn, account_id, device_id, name):
    conn.execute(
        """INSERT INTO devices(account_id, device_id, name) VALUES (%s,%s,%s)
           ON CONFLICT (account_id, device_id) DO UPDATE SET last_seen=now(), name=EXCLUDED.name""",
        (account_id, device_id, name),
    )


# ---- 密钥托管、档案/授权/邀请/转移、设备批准 ----

GRANT_DOCTOR_DAYS = 15       # 非永久授权(grants.days / invites.days)的上限——医生邀请的原型场景
INVITE_TTL_CAP_S = 600       # 邀请链接本身的有效期上限(viewer/普通邀请),不管客户端要求多久
# owner 邀请(代拍→患者的所有权转移)单独给一个更宽的链接有效期上限:病人不一定
# 当场就有空扫码,15 天足够医生等一次;普通 viewer 邀请(医生看诊码)没有这个理由,
# 仍然按 INVITE_TTL_CAP_S 卡在 10 分钟——两者是不同的产品场景,不能共用一个数字。
INVITE_TTL_CAP_OWNER_S = 15 * 86400
LOOKUP_MAX_PER_HOUR = 20     # /v1/accounts/lookup 按调用者账号计数的限流


def b64d(s):
    return base64.b64decode(s) if s is not None else None


def b64e(b):
    return base64.b64encode(bytes(b)).decode() if b is not None else None


def keys_put(conn, aid, body):
    """写账号密钥,**只在还没设过的时候**(`WHERE public_key IS NULL`)。返回改了
    几行:0 = 这个账号已经有密钥了,调用方转 409(见 `app.keys_put`)。

    为什么是一次性的:公钥一换,所有已经用旧公钥封过的 `wrapped_profile_key`
    (自己的档案 + 别人分享给我的)就再也解不开了——那不是"覆盖一个设置",那是
    把云端数据变成垃圾。客户端的阶段机走不到这儿,但这条不可逆的破坏不能只靠
    客户端自律(最终评审 M1)。"""
    cur = conn.execute(
        """UPDATE accounts SET public_key=%s, wrapped_priv_pw=%s, wrapped_priv_rc=%s, kdf_salt=%s, kdf_params=%s
           WHERE id=%s AND public_key IS NULL""",
        (b64d(body["public_key"]), b64d(body["wrapped_priv_pw"]), b64d(body["wrapped_priv_rc"]),
         b64d(body["kdf_salt"]), psycopg.types.json.Jsonb(body["kdf_params"]), aid),
    )
    return cur.rowcount


def keys_get(conn, aid):
    r = conn.execute("SELECT public_key, wrapped_priv_pw, wrapped_priv_rc, kdf_salt, kdf_params FROM accounts WHERE id=%s", (aid,)).fetchone()
    if not r or r[0] is None:
        return None
    return {"public_key": b64e(r[0]), "wrapped_priv_pw": b64e(r[1]), "wrapped_priv_rc": b64e(r[2]), "kdf_salt": b64e(r[3]), "kdf_params": r[4]}


def account_lookup_by_phone_hash(conn, h):
    r = conn.execute("SELECT id, public_key FROM accounts WHERE phone_hash=%s AND public_key IS NOT NULL", (h,)).fetchone()
    return {"account_id": r[0], "public_key": b64e(r[1])} if r else None


def lookup_rate_ok(conn, aid):
    """按调用者账号复用 otp 表的滑动窗口计数器(phone_hash 列借用存 'lookup:<aid>'——
    不是真手机号,不会和真实 phone_hash 撞:那是定长 hex,这里带前缀)。超过
    LOOKUP_MAX_PER_HOUR 返回 False。"""
    key = f"lookup:{aid}"
    row = conn.execute(
        """INSERT INTO otp(phone_hash, code_hash, expires_at, sends_in_window, window_started)
           VALUES (%s, '', now() + interval '1 hour', 1, now())
           ON CONFLICT (phone_hash) DO UPDATE SET
             sends_in_window = CASE WHEN now() - otp.window_started > interval '1 hour' THEN 1 ELSE otp.sends_in_window + 1 END,
             window_started = CASE WHEN now() - otp.window_started > interval '1 hour' THEN now() ELSE otp.window_started END
           RETURNING sends_in_window""",
        (key,)).fetchone()
    return row[0] <= LOOKUP_MAX_PER_HOUR


def profile_create(conn, aid, wrapped_key):
    pid = new_id("prf")
    conn.execute("INSERT INTO profiles(id, owner_account_id) VALUES (%s,%s)", (pid, aid))
    grant_upsert(conn, pid, aid, "owner", None, b64d(wrapped_key), aid)
    return pid


def grant_upsert(conn, pid, grantee_account_id, role, expires_at, wrapped_key, created_by):
    gid = new_id("grt")
    conn.execute(
        # `WHERE grants.role <> 'owner'` 是唯一挡住"两条路径把 owner 降级"的地方
        # (自己给自己发 grant / 兑换一张非 owner 邀请撞上自己已有的 owner 行都会走到
        # 这条 ON CONFLICT):已是 owner 的行,冲突时按兵不动,只有 invite_redeem 里
        # 那条显式的 `UPDATE grants SET role='editor' WHERE role='owner'`(转移专用)
        # 才能改掉 owner。
        """INSERT INTO grants(id, profile_id, grantee_kind, grantee_id, role, expires_at, wrapped_profile_key, created_by)
           VALUES (%s,%s,'account',%s,%s,%s,%s,%s)
           ON CONFLICT (profile_id, grantee_kind, grantee_id) DO UPDATE
             SET role=EXCLUDED.role, expires_at=EXCLUDED.expires_at,
                 wrapped_profile_key=COALESCE(EXCLUDED.wrapped_profile_key, grants.wrapped_profile_key)
             WHERE grants.role <> 'owner'
           RETURNING id""",
        (gid, pid, grantee_account_id, role, expires_at, wrapped_key, created_by),
    )
    return conn.execute("SELECT id FROM grants WHERE profile_id=%s AND grantee_kind='account' AND grantee_id=%s", (pid, grantee_account_id)).fetchone()[0]


def role_for(conn, pid, aid):
    r = conn.execute(
        "SELECT role FROM grants WHERE profile_id=%s AND grantee_kind='account' AND grantee_id=%s AND (expires_at IS NULL OR expires_at > now())",
        (pid, aid)).fetchone()
    return r[0] if r else None


def profiles_for(conn, aid):
    rows = conn.execute(
        """SELECT profile_id, role, expires_at, wrapped_profile_key, id FROM grants
           WHERE grantee_kind='account' AND grantee_id=%s AND (expires_at IS NULL OR expires_at > now())
           ORDER BY created_at""", (aid,)).fetchall()
    return [{"profile_id": r[0], "role": r[1], "expires_at": r[2].isoformat() if r[2] else None,
             "wrapped_profile_key": b64e(r[3]), "grant_id": r[4]} for r in rows]


def grants_list(conn, pid):
    """owner 的「我授权给谁」列表——只选 grant 自身的元数据列,不带 grantee 的
    手机号/姓名(服务端本来就没存这些)。owner 自己那一行也在里面(role='owner'),
    前端按 `role != 'owner'` 自行过滤掉,不在这里假设调用方会怎么用。"""
    rows = conn.execute(
        """SELECT id, grantee_kind, role, expires_at, created_at FROM grants
           WHERE profile_id=%s ORDER BY created_at""", (pid,)).fetchall()
    return [{"grant_id": r[0], "grantee_kind": r[1], "role": r[2],
             "expires_at": r[3].isoformat() if r[3] else None, "created_at": r[4].isoformat()} for r in rows]


def grant_delete(conn, pid, gid):
    cur = conn.execute("DELETE FROM grants WHERE profile_id=%s AND id=%s AND role<>'owner'", (pid, gid))
    return cur.rowcount


def grant_set_key(conn, pid, gid, aid, wrapped_key):
    cur = conn.execute("UPDATE grants SET wrapped_profile_key=%s WHERE profile_id=%s AND id=%s AND grantee_id=%s", (b64d(wrapped_key), pid, gid, aid))
    return cur.rowcount


def invite_create(conn, pid, aid, body):
    iid = new_id("inv")
    # owner(所有权转移)邀请给足 15 天去扫;其余角色(viewer 的医生看诊码……)
    # 仍然卡在 10 分钟——两者是不同的产品场景,见上面 INVITE_TTL_CAP_OWNER_S 的注释。
    cap = INVITE_TTL_CAP_OWNER_S if body.get("role") == "owner" else INVITE_TTL_CAP_S
    ttl = min(int(body.get("invite_ttl_s", 600)), cap)
    days = body.get("days")
    if days:
        days = min(int(days), GRANT_DOCTOR_DAYS)
    conn.execute(
        """INSERT INTO invites(id, profile_id, role, grant_days, token_hash, wrapped_key_by_token, expires_at, created_by)
           VALUES (%s,%s,%s,%s,%s,%s, now() + make_interval(secs => %s), %s)""",
        (iid, pid, body["role"], days, body["token_hash"], b64d(body["wrapped_key_by_token"]), ttl, aid))
    return iid


def invite_redeem(conn, iid, token, aid):
    """返回 (status, payload)。status ∈ ok / notfound / gone / self。"""
    r = conn.execute("SELECT token_hash, created_by FROM invites WHERE id=%s", (iid,)).fetchone()
    if not r or not hmac.compare_digest(r[0], hashlib.sha256(token.encode()).hexdigest()):
        return "notfound", None
    if r[1] == aid:
        return "self", None
    # 把「校验通过」和「标记已兑换」合成一条原子 UPDATE:谁先把 redeemed_by 从
    # NULL 改成非 NULL 谁赢,不会有两个并发请求都读到"还没兑换"然后都兑换成功
    # 的竞态。过期判断也交给数据库的 now(),不再用 Python 里的 time.time()
    # (两边时钟可能不一致,而且这条查询本来就要打数据库)。
    claim = conn.execute(
        """UPDATE invites SET redeemed_by=%s WHERE id=%s AND redeemed_by IS NULL AND expires_at > now()
           RETURNING profile_id, role, grant_days, wrapped_key_by_token, created_by""",
        (aid, iid)).fetchone()
    if not claim:
        return "gone", None
    pid, role, days, wrapped, created_by = claim
    expires_at = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)) if days else None
    if role == "owner":
        # 转移:旧 owner 降 editor,新 owner 上位
        conn.execute("UPDATE grants SET role='editor' WHERE profile_id=%s AND role='owner'", (pid,))
        conn.execute("UPDATE profiles SET owner_account_id=%s WHERE id=%s", (aid, pid))
    gid = grant_upsert(conn, pid, aid, role, expires_at, None, created_by)
    return "ok", {"profile_id": pid, "role": role, "expires_at": expires_at.isoformat() if expires_at else None,
                  "wrapped_key_by_token": b64e(wrapped), "grant_id": gid}


APPROVAL_TTL_HOURS = 24  # 批准了但 24h 内没被取走的 approved_priv,视为过期,清掉


def sweep_stale_approvals(conn):
    """把超过 `APPROVAL_TTL_HOURS` 还没被取走的 `approved_priv` 清空——旧设备
    批准之后,新设备迟迟不来取,密文就一直挂在库里等着被取走,没有必要。清空后
    这台设备回到"未批准"状态,得重新走一遍 request/approve。在
    `device_request`/`device_approve`/`device_take_approval` 这几个必然会打一次
    库的调用里顺手扫一遍,不另起定时任务(ponytail:全表条件扫,`devices` 表量级
    不大,量上来了再考虑加索引/独立任务)。"""
    conn.execute(
        """UPDATE devices SET approved_priv=NULL, approved_at=NULL
           WHERE approved_priv IS NOT NULL AND approved_at < now() - make_interval(hours => %s)""",
        (APPROVAL_TTL_HOURS,),
    )


def device_request(conn, aid, did, eph_public):
    sweep_stale_approvals(conn)
    cur = conn.execute("UPDATE devices SET eph_public=%s WHERE account_id=%s AND device_id=%s", (b64d(eph_public), aid, did))
    return cur.rowcount


def devices_list(conn, aid):
    rows = conn.execute("SELECT device_id, name, last_seen, eph_public, approved_priv IS NOT NULL FROM devices WHERE account_id=%s", (aid,)).fetchall()
    return [{"device_id": r[0], "name": r[1], "last_seen": r[2].isoformat(), "eph_public": b64e(r[3]), "approved": r[4]} for r in rows]


def device_is_trusted(conn, aid, did):
    """一台设备"可信"= 它自己没有正等待批准的请求、也没有等着被取走的批准密文
    (eph_public/approved_priv 都是 NULL)。全新账号的第一台设备从登录起就是这个
    状态,天然可信;走完 request→approve→take 一圈的设备,take 完之后也回到这个
    状态。批准别的设备之前,批准者自己必须先在这个状态。"""
    r = conn.execute("SELECT approved_priv IS NULL AND eph_public IS NULL FROM devices WHERE account_id=%s AND device_id=%s", (aid, did)).fetchone()
    return bool(r and r[0])


def device_approve(conn, aid, did, approved_priv):
    sweep_stale_approvals(conn)
    cur = conn.execute(
        "UPDATE devices SET approved_priv=%s, approved_at=now(), eph_public=NULL WHERE account_id=%s AND device_id=%s",
        (b64d(approved_priv), aid, did),
    )
    return cur.rowcount


def device_take_approval(conn, aid, did):
    sweep_stale_approvals(conn)
    # ponytail: RETURNING approved_priv on the same UPDATE that nulls it returns the
    # POST-update (NULL) value, not the value being taken — that's a real Postgres
    # RETURNING-semantics bug, not a style choice. SELECT ... FOR UPDATE then UPDATE,
    # same transaction, so the read+clear stays atomic against a concurrent take.
    r = conn.execute("SELECT approved_priv FROM devices WHERE account_id=%s AND device_id=%s AND approved_priv IS NOT NULL FOR UPDATE", (aid, did)).fetchone()
    if not r:
        return None
    conn.execute("UPDATE devices SET approved_priv=NULL, approved_at=NULL WHERE account_id=%s AND device_id=%s", (aid, did))
    return b64e(r[0])


# ---- 事件推拉、对象登记、用量(Task 6) ----

EVENT_MAX_BYTES = 1024 * 1024   # 1 MiB:单条事件密文上限
MAX_EVENTS_PER_PUSH = 500       # 单次推送最多多少条事件
_HEX64 = re.compile(r"[0-9a-f]{64}")


def validate_event(e):
    """校验单条事件的形状。通过返回 None,否则返回出错的字段名——只挡明显畸形的
    输入(类型不对、缺字段、base64 解不出来),不做业务语义校验,免得随手一条
    NaN/缺字段/坏 base64 就把整个请求炸成 500。"""
    if not isinstance(e, dict):
        return "event"
    device_id = e.get("device_id")
    if not isinstance(device_id, str) or not (0 < len(device_id) <= 64):
        return "device_id"
    seq = e.get("seq")
    if not isinstance(seq, int) or isinstance(seq, bool) or seq < 0:
        return "seq"
    event_id = e.get("event_id")
    if not isinstance(event_id, str) or not _HEX64.fullmatch(event_id):
        return "event_id"
    # `ts`:客户端从最终评审 I4 起一律发常量 `"0"`——事件的真实时间戳只在密文里
    # (明文发出来等于白送服务端一条"这个人什么时候看了什么科"的时间线,而服务端
    # 排序只用 (device_id, seq),压根不看它)。这里仍然要求是个非空短字符串:老
    # 客户端发的 ISO 时间戳照样收,不为一个字段搞版本分支。
    ts = e.get("ts")
    if not isinstance(ts, str) or not (0 < len(ts) <= 64):
        return "ts"
    ciphertext = e.get("ciphertext")
    if not isinstance(ciphertext, str):
        return "ciphertext"
    try:
        raw = base64.b64decode(ciphertext, validate=True)
    except (binascii.Error, ValueError):
        return "ciphertext"
    if len(raw) > EVENT_MAX_BYTES:
        return "ciphertext"
    return None


def events_push(conn, pid, events):
    for e in events:
        conn.execute(
            """INSERT INTO events(profile_id, device_id, seq, event_id, ts, ciphertext) VALUES (%s,%s,%s,%s,%s,%s)
               ON CONFLICT (profile_id, device_id, seq) DO NOTHING""",
            (pid, e["device_id"], int(e["seq"]), e["event_id"], e["ts"], b64d(e["ciphertext"])))


def events_pull(conn, pid, since: dict):
    """返回 (events, seq_map)。seq_map 是本档案全部设备当前的最大 seq(不受 since
    过滤),客户端拿它当下一次的 since 游标——含它自己没查过的设备。
    ponytail: 每次全表扫一遍本档案所有事件再在 Python 里过滤,档案事件多了会变慢——
    量上来了再改成按 device_id 分别查 `seq > since` 且 seq_map 走 GROUP BY MAX(seq)。"""
    rows = conn.execute("SELECT device_id, seq, event_id, ts, ciphertext FROM events WHERE profile_id=%s ORDER BY device_id, seq", (pid,)).fetchall()
    seq_map = {}
    events = []
    for r in rows:
        device_id, seq = r[0], r[1]
        if seq > seq_map.get(device_id, 0):
            seq_map[device_id] = seq
        if seq > int(since.get(device_id, 0)):
            events.append({"device_id": device_id, "seq": seq, "event_id": r[2], "ts": r[3], "ciphertext": b64e(r[4])})
    return events, seq_map


def object_register(conn, pid, aid, oid, size):
    conn.execute("INSERT INTO objects(profile_id, object_id, size) VALUES (%s,%s,%s) ON CONFLICT DO NOTHING", (pid, oid, size))
    usage_add(conn, aid, storage_bytes=size)


def objects_list(conn, pid):
    return [r[0] for r in conn.execute("SELECT object_id FROM objects WHERE profile_id=%s ORDER BY created_at", (pid,)).fetchall()]


# ---- 自助注销(Task 15) ----


def account_delete(conn, aid):
    """自助注销一个账号,DB 这一半 all-or-nothing(同一个事务,调用方的
    `conn_dep` 负责提交/回滚)。

    顺序:① 这个账号名下**拥有**的档案——整个删掉,靠外键 `ON DELETE CASCADE`
    (`grants`/`events`/`objects`/`invites` 的 `profile_id` 都指向 `profiles`)
    连带清掉,不用在这里逐张表手写;删之前先把这些档案下全部对象的 OSS key
    (`v/<pid>/<oid>`)记下来返回,调用方在 DB 提交之后再去删 OSS(最佳努力,
    见 `app.py`)。② 这个账号作为 grantee 分享到的**别人的**档案——只删这一行
    grant,不碰那个档案本身(它属于别人,别人的数据在别人删号之前不该受影响)。
    ③ usage/otp(含正常的 phone_hash 那行,和 `lookup_rate_ok` 借用的
    `lookup:<aid>` 那行)。④ account 行本身——`devices` 有
    `ON DELETE CASCADE` 到 accounts,顺带清掉,不用单独删。
    """
    owned = [r[0] for r in conn.execute("SELECT id FROM profiles WHERE owner_account_id=%s", (aid,)).fetchall()]
    oss_keys = []
    if owned:
        rows = conn.execute(
            "SELECT profile_id, object_id FROM objects WHERE profile_id = ANY(%s)", (owned,)
        ).fetchall()
        oss_keys = [f"v/{pid}/{oid}" for pid, oid in rows]
        conn.execute("DELETE FROM profiles WHERE owner_account_id=%s", (aid,))
    conn.execute("DELETE FROM grants WHERE grantee_kind='account' AND grantee_id=%s", (aid,))
    conn.execute("DELETE FROM usage WHERE account_id=%s", (aid,))
    r = conn.execute("SELECT phone_hash FROM accounts WHERE id=%s", (aid,)).fetchone()
    phone_hash = r[0] if r else None
    otp_keys = [f"lookup:{aid}"] + ([phone_hash] if phone_hash else [])
    conn.execute("DELETE FROM otp WHERE phone_hash = ANY(%s)", (otp_keys,))
    conn.execute("DELETE FROM accounts WHERE id=%s", (aid,))
    return oss_keys


def usage_tokens_this_month(conn, aid):
    """本月这个账号已用的 LLM token(in + out)。没有记录就是 0。
    `/v1/extract` 的月度天花板按它判(见 `app.extract_route`)。"""
    r = conn.execute(
        "SELECT llm_tokens_in + llm_tokens_out FROM usage WHERE account_id=%s AND month=%s",
        (aid, time.strftime("%Y-%m")),
    ).fetchone()
    return r[0] if r else 0


def usage_add(conn, aid, *, tokens_in=0, tokens_out=0, storage_bytes=0):
    month = time.strftime("%Y-%m")
    conn.execute(
        """INSERT INTO usage(account_id, month, llm_tokens_in, llm_tokens_out, storage_bytes) VALUES (%s,%s,%s,%s,%s)
           ON CONFLICT (account_id, month) DO UPDATE SET llm_tokens_in=usage.llm_tokens_in+EXCLUDED.llm_tokens_in,
             llm_tokens_out=usage.llm_tokens_out+EXCLUDED.llm_tokens_out, storage_bytes=usage.storage_bytes+EXCLUDED.storage_bytes""",
        (aid, month, tokens_in, tokens_out, storage_bytes))
