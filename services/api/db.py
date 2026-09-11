"""建表 + 全部查询。所有函数接收 psycopg.Connection;没有 ORM。
服务端只存密文与账号业务数据:任何列都不该出现明文病历、档案密钥、私钥、口令。"""
import os
import secrets
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
