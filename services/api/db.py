"""建表 + 全部查询。所有函数接收 psycopg.Connection;没有 ORM。
服务端只存密文与账号业务数据:任何列都不该出现明文病历、档案密钥、私钥、口令。"""
import base64
import datetime
import hashlib
import hmac
import os
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

def b64d(s):
    return base64.b64decode(s) if s is not None else None


def b64e(b):
    return base64.b64encode(bytes(b)).decode() if b is not None else None


def keys_put(conn, aid, body):
    conn.execute(
        """UPDATE accounts SET public_key=%s, wrapped_priv_pw=%s, wrapped_priv_rc=%s, kdf_salt=%s, kdf_params=%s WHERE id=%s""",
        (b64d(body["public_key"]), b64d(body["wrapped_priv_pw"]), b64d(body["wrapped_priv_rc"]),
         b64d(body["kdf_salt"]), psycopg.types.json.Jsonb(body["kdf_params"]), aid),
    )


def keys_get(conn, aid):
    r = conn.execute("SELECT public_key, wrapped_priv_pw, wrapped_priv_rc, kdf_salt, kdf_params FROM accounts WHERE id=%s", (aid,)).fetchone()
    if not r or r[0] is None:
        return None
    return {"public_key": b64e(r[0]), "wrapped_priv_pw": b64e(r[1]), "wrapped_priv_rc": b64e(r[2]), "kdf_salt": b64e(r[3]), "kdf_params": r[4]}


def account_lookup_by_phone_hash(conn, h):
    r = conn.execute("SELECT id, public_key FROM accounts WHERE phone_hash=%s AND public_key IS NOT NULL", (h,)).fetchone()
    return {"account_id": r[0], "public_key": b64e(r[1])} if r else None


def profile_create(conn, aid, wrapped_key):
    pid = new_id("prf")
    conn.execute("INSERT INTO profiles(id, owner_account_id) VALUES (%s,%s)", (pid, aid))
    grant_upsert(conn, pid, aid, "owner", None, b64d(wrapped_key), aid)
    return pid


def grant_upsert(conn, pid, grantee_account_id, role, expires_at, wrapped_key, created_by):
    gid = new_id("grt")
    conn.execute(
        """INSERT INTO grants(id, profile_id, grantee_kind, grantee_id, role, expires_at, wrapped_profile_key, created_by)
           VALUES (%s,%s,'account',%s,%s,%s,%s,%s)
           ON CONFLICT (profile_id, grantee_kind, grantee_id) DO UPDATE
             SET role=EXCLUDED.role, expires_at=EXCLUDED.expires_at,
                 wrapped_profile_key=COALESCE(EXCLUDED.wrapped_profile_key, grants.wrapped_profile_key)
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


def grant_delete(conn, pid, gid):
    conn.execute("DELETE FROM grants WHERE profile_id=%s AND id=%s AND role<>'owner'", (pid, gid))


def grant_set_key(conn, pid, gid, aid, wrapped_key):
    conn.execute("UPDATE grants SET wrapped_profile_key=%s WHERE profile_id=%s AND id=%s AND grantee_id=%s", (b64d(wrapped_key), pid, gid, aid))


def invite_create(conn, pid, aid, body):
    iid = new_id("inv")
    ttl = int(body.get("invite_ttl_s", 600))
    conn.execute(
        """INSERT INTO invites(id, profile_id, role, grant_days, token_hash, wrapped_key_by_token, expires_at, created_by)
           VALUES (%s,%s,%s,%s,%s,%s, now() + make_interval(secs => %s), %s)""",
        (iid, pid, body["role"], body.get("days"), body["token_hash"], b64d(body["wrapped_key_by_token"]), ttl, aid))
    return iid


def invite_redeem(conn, iid, token, aid):
    """返回 (status, payload)。status ∈ ok / notfound / gone。"""
    r = conn.execute("SELECT profile_id, role, grant_days, token_hash, wrapped_key_by_token, expires_at, redeemed_by, created_by FROM invites WHERE id=%s", (iid,)).fetchone()
    if not r or not hmac.compare_digest(r[3], hashlib.sha256(token.encode()).hexdigest()):
        return "notfound", None
    pid, role, days, _, wrapped, exp, redeemed_by, created_by = r
    if redeemed_by is not None or exp.timestamp() < time.time():
        return "gone", None
    expires_at = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)) if days else None
    if role == "owner":
        # 转移:旧 owner 降 editor,新 owner 上位
        conn.execute("UPDATE grants SET role='editor' WHERE profile_id=%s AND role='owner'", (pid,))
        conn.execute("UPDATE profiles SET owner_account_id=%s WHERE id=%s", (aid, pid))
    gid = grant_upsert(conn, pid, aid, role, expires_at, None, created_by)
    conn.execute("UPDATE invites SET redeemed_by=%s WHERE id=%s", (aid, iid))
    return "ok", {"profile_id": pid, "role": role, "expires_at": expires_at.isoformat() if expires_at else None,
                  "wrapped_key_by_token": b64e(wrapped), "grant_id": gid}


def device_request(conn, aid, did, eph_public):
    conn.execute("UPDATE devices SET eph_public=%s WHERE account_id=%s AND device_id=%s", (b64d(eph_public), aid, did))


def devices_list(conn, aid):
    rows = conn.execute("SELECT device_id, name, last_seen, eph_public, approved_priv IS NOT NULL FROM devices WHERE account_id=%s", (aid,)).fetchall()
    return [{"device_id": r[0], "name": r[1], "last_seen": r[2].isoformat(), "eph_public": b64e(r[3]), "approved": r[4]} for r in rows]


def device_approve(conn, aid, did, approved_priv):
    conn.execute("UPDATE devices SET approved_priv=%s, eph_public=NULL WHERE account_id=%s AND device_id=%s", (b64d(approved_priv), aid, did))


def device_take_approval(conn, aid, did):
    # ponytail: RETURNING approved_priv on the same UPDATE that nulls it returns the
    # POST-update (NULL) value, not the value being taken — that's a real Postgres
    # RETURNING-semantics bug, not a style choice. SELECT ... FOR UPDATE then UPDATE,
    # same transaction, so the read+clear stays atomic against a concurrent take.
    r = conn.execute("SELECT approved_priv FROM devices WHERE account_id=%s AND device_id=%s AND approved_priv IS NOT NULL FOR UPDATE", (aid, did)).fetchone()
    if not r:
        return None
    conn.execute("UPDATE devices SET approved_priv=NULL WHERE account_id=%s AND device_id=%s", (aid, did))
    return b64e(r[0])
