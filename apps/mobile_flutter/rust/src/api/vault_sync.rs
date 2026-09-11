//! 云同步 FRB 面。Rust 只做密码学与本地读写;HTTP 在 Dart(`sync_engine.dart`)。
//!
//! 全部函数 `sync_` 前缀(见 `api::mod` 的 wire 序号纪律注释)。`with_state` /
//! `vault_cell` / `VaultState` / `machine_device_id` 复用 `api::vault` 的
//! (那边已改 `pub(crate)`),不重开一份进程级单例——同一进程同一时刻只认一个
//! 打开的 vault,keyed 与 unkeyed 共享同一把锁/同一个 FIFO(ADR 0008),
//! `sync_open_profile_vault` 只是换一种方式构造 `VaultState`(带上 `profile_key`)。
use crate::api::dto::{SyncEventDto, SyncImportOutcomeDto};
use crate::api::vault::{machine_device_id, vault_cell, with_state, VaultState};
use core_model::{LogEntry, Vault};
use std::path::PathBuf;

/// FRB 边界统一按定长密钥收发(`Vec<u8>` 是 Dart `Uint8List` 的唯一对应类型,
/// 没有定长数组绑定),内部一律转回 `[u8; 32]` 再喂给 `packages/sync`。
fn key32(v: &[u8]) -> anyhow::Result<[u8; 32]> {
    v.try_into()
        .map_err(|_| anyhow::anyhow!("密钥必须是 32 字节"))
}

pub fn sync_account_keys_new() -> (Vec<u8>, Vec<u8>) {
    let k = sync::account_keys_new();
    (k.public.to_vec(), k.secret.to_vec())
}

pub fn sync_wrap_private(
    secret: Vec<u8>,
    password: String,
    salt: Vec<u8>,
    m_kib: u32,
    t: u32,
    p: u32,
) -> anyhow::Result<Vec<u8>> {
    let salt: [u8; 16] = salt
        .try_into()
        .map_err(|_| anyhow::anyhow!("salt 必须 16 字节"))?;
    let kek = sync::kek_from_password(&password, &salt, &sync::KdfParams { m_kib, t, p })?;
    Ok(sync::wrap(&kek, &secret, b"account-priv-v1")?)
}

pub fn sync_unwrap_private_pw(
    blob: Vec<u8>,
    password: String,
    salt: Vec<u8>,
    m_kib: u32,
    t: u32,
    p: u32,
) -> anyhow::Result<Vec<u8>> {
    let salt: [u8; 16] = salt
        .try_into()
        .map_err(|_| anyhow::anyhow!("salt 必须 16 字节"))?;
    let kek = sync::kek_from_password(&password, &salt, &sync::KdfParams { m_kib, t, p })?;
    Ok(sync::unwrap(&kek, &blob, b"account-priv-v1")?)
}

pub fn sync_recovery_code_new() -> String {
    sync::recovery_code_new()
}

pub fn sync_wrap_private_rc(secret: Vec<u8>, code: String) -> anyhow::Result<Vec<u8>> {
    let kek = sync::kek_from_recovery(&code)?;
    Ok(sync::wrap(&kek, &secret, b"account-priv-v1")?)
}

pub fn sync_unwrap_private_rc(blob: Vec<u8>, code: String) -> anyhow::Result<Vec<u8>> {
    let kek = sync::kek_from_recovery(&code)?;
    Ok(sync::unwrap(&kek, &blob, b"account-priv-v1")?)
}

/// 邀请场景:`kek = HKDF(token)`(见 `sync::kek_from_token`,salt
/// `medme-invite-v1`,与口令/恢复码的 `account-priv-v1` AAD 分开用 `invite-v1`)。
pub fn sync_wrap_with_token(plaintext: Vec<u8>, token: String) -> anyhow::Result<Vec<u8>> {
    let kek = sync::kek_from_token(&token)?;
    Ok(sync::wrap(&kek, &plaintext, b"invite-v1")?)
}

pub fn sync_unwrap_with_token(blob: Vec<u8>, token: String) -> anyhow::Result<Vec<u8>> {
    let kek = sync::kek_from_token(&token)?;
    Ok(sync::unwrap(&kek, &blob, b"invite-v1")?)
}

pub fn sync_profile_key_new() -> Vec<u8> {
    sync::profile_key_new().to_vec()
}

pub fn sync_seal_to(public: Vec<u8>, plaintext: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    let public = key32(&public)?;
    Ok(sync::seal_to(&public, &plaintext)?)
}

pub fn sync_open_sealed(secret: Vec<u8>, blob: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    let secret = key32(&secret)?;
    Ok(sync::open_sealed(&secret, &blob)?)
}

/// 与 `open_vault` 同布局(`<docs_dir>/vault` 真相 + `<data_dir>` 本机设备
/// id),但用档案密钥 keyed 打开(`Vault::open_split_resilient_with_key`),
/// 且不走 iCloud——云账号同步是另一条同步路径,两者不共用 iCloud 容器解析。
pub fn sync_open_profile_vault(
    docs_dir: String,
    data_dir: String,
    profile_key: Vec<u8>,
) -> anyhow::Result<()> {
    let pk = key32(&profile_key)?;
    let docs = PathBuf::from(docs_dir);
    let data = PathBuf::from(data_dir);
    std::fs::create_dir_all(&docs)?;
    std::fs::create_dir_all(&data)?;
    let device_id = machine_device_id(&data)?;
    let truth = docs.join("vault");
    let db = truth.join("medme.db");
    let vault = Vault::open_split_resilient_with_key(&truth, &db, &device_id, &pk)
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    let mut guard = vault_cell().lock().unwrap_or_else(|p| p.into_inner());
    *guard = Some(VaultState {
        vault,
        truth_root: truth,
        db_path: db,
        device_id,
        docs_dir: docs,
        data_dir: data,
        profile_key: Some(pk),
    });
    Ok(())
}

/// 本机每个 device 段当前**可信**的最大 seq(见
/// `core_model::sync_io::device_seq_map` 文档:被隔离的条目不计入)。推送前
/// 拿这个当"服务端已有到哪"的起点,拉取前当"本机已有到哪"的水位。
pub fn sync_local_seq_map() -> anyhow::Result<Vec<(String, i64)>> {
    with_state(|s| {
        Ok(s.vault
            .device_seq_map()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .into_iter()
            .collect())
    })
}

/// 导出本机日志里 `seq > after[device_id]`(未提供该 device 则视为 0)的条目,
/// 逐条整体加密(AAD = `event_id`,防止信封字段与密文错配后被悄悄接受)。
pub fn sync_export_events(
    profile_key: Vec<u8>,
    after: Vec<(String, i64)>,
) -> anyhow::Result<Vec<SyncEventDto>> {
    let pk = key32(&profile_key)?;
    let after: std::collections::HashMap<String, i64> = after.into_iter().collect();
    with_state(|s| {
        let mut out = Vec::new();
        for e in s
            .vault
            .log_entries()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
        {
            if e.seq <= after.get(&e.device_id).copied().unwrap_or(0) {
                continue;
            }
            let plain = serde_json::to_vec(&e)?;
            let ct = sync::encrypt_blob(&pk, &e.event_id, &plain)?;
            out.push(SyncEventDto {
                device_id: e.device_id.clone(),
                seq: e.seq,
                event_id: e.event_id.clone(),
                ts: e.ts.clone(),
                ciphertext: ct,
            });
        }
        Ok(out)
    })
}

/// 解密 + 校验信封字段与解密出的条目一致(拒收错配),交给
/// `append_peer_entries` 按 `(device_id, seq)` 去重/校验链/MAC 落盘。
pub fn sync_import_events(
    profile_key: Vec<u8>,
    events: Vec<SyncEventDto>,
) -> anyhow::Result<SyncImportOutcomeDto> {
    let pk = key32(&profile_key)?;
    let mut entries = Vec::with_capacity(events.len());
    for ev in events {
        let plain = sync::decrypt_blob(&pk, &ev.event_id, &ev.ciphertext)?;
        let entry: LogEntry = serde_json::from_slice(&plain)?;
        if entry.event_id != ev.event_id || entry.device_id != ev.device_id || entry.seq != ev.seq
        {
            anyhow::bail!("事件信封与内容不一致,拒收");
        }
        entries.push(entry);
    }
    with_state(|s| {
        let outcome = s
            .vault
            .append_peer_entries(&entries)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(SyncImportOutcomeDto {
            applied: outcome.applied as u32,
            skipped_existing: outcome.skipped_existing as u32,
            out_of_order: outcome.out_of_order as u32,
            untrusted: outcome.untrusted as u32,
        })
    })
}

/// 事件引用了、但本机 `objects/` 里还没有的对象——按 `object_id`(服务端可见的
/// 别名,内容哈希经档案密钥 HMAC)列出待拉清单。
pub fn sync_missing_objects(profile_key: Vec<u8>) -> anyhow::Result<Vec<(String, String)>> {
    let pk = key32(&profile_key)?;
    with_state(|s| {
        s.vault
            .missing_object_hashes()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .into_iter()
            .map(|h| {
                let id = sync::object_id(&pk, &h)?;
                Ok((h, id))
            })
            .collect::<anyhow::Result<Vec<_>>>()
    })
}

/// 本机日志引用、且已在 CAS 落地的对象全量清单(推送用)——同一批哈希来源与
/// `missing_object_hashes` 一致,只是反过来只留「本地已有」的。
pub fn sync_all_object_ids(profile_key: Vec<u8>) -> anyhow::Result<Vec<(String, String)>> {
    let pk = key32(&profile_key)?;
    with_state(|s| {
        let mut out: Vec<(String, String)> = Vec::new();
        for e in s
            .vault
            .log_entries()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
        {
            let h = match &e.event {
                core_model::Event::FileImported { content_hash, .. } => content_hash.clone(),
                core_model::Event::OcrAdded { text_hash, .. } => text_hash.clone(),
                _ => continue,
            };
            if out.iter().any(|(x, _)| x == &h) {
                continue;
            }
            if s.vault
                .root_join(&core_model::cas::object_relpath(&h))
                .exists()
            {
                let id = sync::object_id(&pk, &h)?;
                out.push((h, id));
            }
        }
        Ok(out)
    })
}

/// 读本地 CAS 对象 + 加密(AAD = `object_id`)供上传;`object_id` 一并带回,
/// 调用方(Dart)不需要在本地重算一遍。
pub fn sync_encrypt_object(profile_key: Vec<u8>, hash: String) -> anyhow::Result<(String, Vec<u8>)> {
    let pk = key32(&profile_key)?;
    with_state(|s| {
        let bytes = s
            .vault
            .read_object(&hash)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let id = sync::object_id(&pk, &hash)?;
        let ct = sync::encrypt_blob(&pk, &id, &bytes)?;
        Ok((id, ct))
    })
}

/// 解密拉回来的对象、存入本地 CAS,并校验解密出的明文哈希经档案密钥算出的
/// `object_id` 与传入的 `object_id` 一致(内容与其服务端别名对不上就丢弃,
/// 不落库)。`store_object` 已存在则不重写(见其文档:已存在的对象跳过写入),
/// 但这条校验仍然执行。写完后 `materialize` 一次,让新对象覆盖到的文档立刻
/// 可见(单独对象拉取的调用方——即本函数——负责这一步)。
pub fn sync_store_object(
    profile_key: Vec<u8>,
    object_id: String,
    ciphertext: Vec<u8>,
) -> anyhow::Result<String> {
    let pk = key32(&profile_key)?;
    let plain = sync::decrypt_blob(&pk, &object_id, &ciphertext)?;
    with_state(|s| {
        let (h, _, _) = s
            .vault
            .store_object(&plain)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        if sync::object_id(&pk, &h)? != object_id {
            anyhow::bail!("对象内容与 object_id 不符,已丢弃");
        }
        s.vault
            .materialize()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(h)
    })
}

pub fn sync_date_shift_days(profile_key: Vec<u8>) -> anyhow::Result<i32> {
    Ok(sync::date_shift_days(&key32(&profile_key)?))
}

/// Argon2id KDF 真机基准(设置页/首次建号按结果调参数,不写死 `KDF_DEFAULT`)。
pub fn sync_kdf_bench_ms(m_kib: u32, t: u32, p: u32) -> u64 {
    let t0 = std::time::Instant::now();
    let _ = sync::kek_from_password("bench", &[0u8; 16], &sync::KdfParams { m_kib, t, p });
    t0.elapsed().as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::vault::VAULT_TEST_LOCK;
    use tempfile::tempdir;

    #[test]
    fn export_import_round_trip_between_two_devices() {
        // 这两个测试跟 `vault_projections` 的端到端测试共用同一个进程级 `VAULT`
        // 单例,`cargo test` 默认并发跑线程会互相践踏——串行化见
        // `api::vault::VAULT_TEST_LOCK` 的文档。
        let _guard = VAULT_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let pk = sync_profile_key_new();
        let a = tempdir().unwrap();
        sync_open_profile_vault(
            a.path().to_string_lossy().into(),
            a.path().join("data").to_string_lossy().into(),
            pk.clone(),
        )
        .unwrap();
        crate::api::vault::ingest_bytes("r.txt".into(), b"WBC 5.0".to_vec()).unwrap();
        let events = sync_export_events(pk.clone(), vec![]).unwrap();
        assert!(!events.is_empty());
        let objs = sync_all_object_ids(pk.clone()).unwrap();
        assert_eq!(objs.len(), 1, "一份纯文本导入只挂一个 CAS 对象(源文件字节)");
        let (oid, ct) = sync_encrypt_object(pk.clone(), objs[0].0.clone()).unwrap();
        let docs_before = crate::api::vault::load_archive().unwrap().len();

        let b = tempdir().unwrap();
        sync_open_profile_vault(
            b.path().to_string_lossy().into(),
            b.path().join("data").to_string_lossy().into(),
            pk.clone(),
        )
        .unwrap();
        let outcome = sync_import_events(pk.clone(), events.clone()).unwrap();
        assert_eq!(outcome.applied as usize, events.len());
        assert_eq!(outcome.skipped_existing, 0);
        assert_eq!(outcome.out_of_order, 0);
        assert_eq!(outcome.untrusted, 0, "同一把档案密钥,不应被隔离");

        assert_eq!(sync_missing_objects(pk.clone()).unwrap()[0].1, oid);
        let h = sync_store_object(pk.clone(), oid, ct).unwrap();
        assert_eq!(h, objs[0].0);
        assert!(sync_missing_objects(pk.clone()).unwrap().is_empty());

        // 对象补齐 + materialize 之后,B 的文档数应与 A 一致(同一份日志重放）。
        let docs_after = crate::api::vault::load_archive().unwrap().len();
        assert_eq!(docs_after, docs_before, "B 重放出的文档数应与 A 一致");

        // 重推同一批事件:精确 (device_id, seq) 已在磁盘,按存在跳过。
        let outcome2 = sync_import_events(pk, events.clone()).unwrap();
        assert_eq!(outcome2.applied, 0);
        assert_eq!(outcome2.skipped_existing as usize, events.len());
    }

    #[test]
    fn kdf_bench_runs() {
        assert!(sync_kdf_bench_ms(8192, 1, 1) < 5_000);
    }

    #[test]
    fn wrap_unwrap_private_pw_and_rc_and_token_round_trip() {
        let (_public, secret) = sync_account_keys_new();
        let salt = vec![3u8; 16];
        let wrapped = sync_wrap_private(secret.clone(), "口令".into(), salt.clone(), 8192, 1, 1).unwrap();
        let back = sync_unwrap_private_pw(wrapped, "口令".into(), salt, 8192, 1, 1).unwrap();
        assert_eq!(back, secret);

        let code = sync_recovery_code_new();
        let wrapped_rc = sync_wrap_private_rc(secret.clone(), code.clone()).unwrap();
        assert_eq!(sync_unwrap_private_rc(wrapped_rc, code).unwrap(), secret);

        let token = "invite-token-abc".to_string();
        let wrapped_tok = sync_wrap_with_token(secret.clone(), token.clone()).unwrap();
        assert_eq!(sync_unwrap_with_token(wrapped_tok, token).unwrap(), secret);
    }

    #[test]
    fn seal_round_trips_profile_key() {
        let (public, secret) = sync_account_keys_new();
        let pk = sync_profile_key_new();
        let sealed = sync_seal_to(public, pk.clone()).unwrap();
        assert_eq!(sync_open_sealed(secret, sealed).unwrap(), pk);
    }
}
