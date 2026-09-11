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
///
/// **打开前先探测密钥是否对得上**(`core_model::log::EventLog::probe_key_mismatch`,
/// 只读、不碰盘):这个密钥是外部传入的(账号恢复/邀请链路,不是本机生成后立刻
/// 确认过的),用错的密钥直接走 `Vault::open_split_resilient_with_key` 有真实
/// 破坏性——`open_inner` 见 `read_all()` 因为 MAC 全验不过而判定日志为空,若
/// 派生库(`medme.db`,同一 `truth_root` 下之前用正确密钥打开时已经物化过)
/// 还有行,就会误判成"预 refactor 的纯 DB vault",从 DB 反向合成一份新日志
/// (`migrate_db_to_log`)——凭空多出一个设备段文件,而且这个动作发生在
/// `open_inner` 内部、返回错误也来不及挽回。必须在调用它之前就拒绝。
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
    if core_model::log::EventLog::probe_key_mismatch(&truth, &pk)
        .map_err(|e| anyhow::anyhow!(e.to_string()))?
    {
        anyhow::bail!("档案密钥不匹配");
    }
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

/// 当前打开的 vault 是否是 keyed(云同步档案)打开的——`Task 8` 的 Dart 侧要
/// 靠它区分"这是本机保险箱还是账号档案",FIFO 队列怎么排开箱请求也看这个。
/// 未打开任何 vault 时返回 `false`(而不是报错),供 UI 直接拿去判断显示。
pub fn sync_current_vault_is_keyed() -> bool {
    with_state(|s| Ok(s.profile_key.is_some())).unwrap_or(false)
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
///
/// **一条解不开就按设备截断,不是整批放弃**:先按 `(device_id, seq)` 排序
/// (与 `append_peer_entries` 自己的排序口径一致,不依赖调用方传入顺序),
/// 逐条尝试解密+反序列化+信封一致性校验;某个设备撞到第一条解不开的
/// (密文损坏、或对方用了本地还不认识的 `Event` 变体导致反序列化失败)就停止
/// 收它后面的条目——即使后面的条目本身能解开也不收,因为 `append_peer_entries`
/// 要求同一设备段严格按 seq 递增落盘,跳过中间一条去接后面的会在这个设备段里
/// 留一个洞,读回来时被判定成链断裂而整体隔离(比这里主动跳过更糟)。**其它
/// 设备的条目不受影响**,继续正常处理——一台设备写坏一条不该拖累全体同步
/// 卡死。`undecodable` 记的是"撞到的第一条解不开的条目数"(每台受影响设备
/// 最多算一条,它之后被跳过的条目不再单独计数)。
pub fn sync_import_events(
    profile_key: Vec<u8>,
    mut events: Vec<SyncEventDto>,
) -> anyhow::Result<SyncImportOutcomeDto> {
    let pk = key32(&profile_key)?;
    events.sort_by(|a, b| (a.device_id.as_str(), a.seq).cmp(&(b.device_id.as_str(), b.seq)));

    let mut entries = Vec::with_capacity(events.len());
    let mut stopped_devices: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut undecodable: u32 = 0;
    for ev in events {
        if stopped_devices.contains(&ev.device_id) {
            continue;
        }
        let decoded: anyhow::Result<LogEntry> = (|| {
            let plain = sync::decrypt_blob(&pk, &ev.event_id, &ev.ciphertext)?;
            let entry: LogEntry = serde_json::from_slice(&plain)?;
            if entry.event_id != ev.event_id
                || entry.device_id != ev.device_id
                || entry.seq != ev.seq
            {
                anyhow::bail!("事件信封与内容不一致,拒收");
            }
            Ok(entry)
        })();
        match decoded {
            Ok(entry) => entries.push(entry),
            Err(_) => {
                stopped_devices.insert(ev.device_id);
                undecodable += 1;
            }
        }
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
            undecodable,
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

/// 从一条事件里取出它引用的对象哈希——只认 `FileImported`/`OcrAdded`,并且
/// 必须是合法的 64 位小写 hex(`cas::is_object_hash`)。**这道闸不是多余的**:
/// 同一把档案密钥的另一台设备也能造出通过 MAC 校验的合法条目(它拥有同一把
/// 密钥,不需要伪造 MAC),所以哈希字段本身仍是不可信输入——下游
/// `object_relpath` 会拿它切片拼路径,短于 4 字节/带 `..`/`/` 会 panic 或逃出
/// `objects/`(见该函数文档)。与 `missing_object_hashes` 同一口径。
fn object_hash_from_event(event: &core_model::Event) -> Option<String> {
    let h = match event {
        core_model::Event::FileImported { content_hash, .. } => content_hash,
        core_model::Event::OcrAdded { text_hash, .. } => text_hash,
        _ => return None,
    };
    core_model::cas::is_object_hash(h).then(|| h.clone())
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
            let Some(h) = object_hash_from_event(&e.event) else {
                continue;
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
/// `object_id` 与传入的 `object_id` 一致(内容与其服务端别名对不上就拒绝——
/// **校验先于落盘**:先算 `sha256`/`object_id` 比对,对不上直接返回 `Err`,
/// `store_object` 一次都不调用,`objects/` 下不会出现任何与传入 `object_id`
/// 对不上的文件。`store_object` 本身已存在则不重写(见其文档),但那是校验
/// 通过之后的事。写完后 `materialize` 一次,让新对象覆盖到的文档立刻可见
/// (单独对象拉取的调用方——即本函数——负责这一步)。
pub fn sync_store_object(
    profile_key: Vec<u8>,
    object_id: String,
    ciphertext: Vec<u8>,
) -> anyhow::Result<String> {
    let pk = key32(&profile_key)?;
    let plain = sync::decrypt_blob(&pk, &object_id, &ciphertext)?;
    let h = core_model::cas::sha256_hex(&plain);
    if sync::object_id(&pk, &h)? != object_id {
        anyhow::bail!("对象内容与 object_id 不符,拒绝写入");
    }
    with_state(|s| {
        let (stored_h, _, _) = s
            .vault
            .store_object(&plain)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        debug_assert_eq!(stored_h, h, "store_object 自算的哈希应与校验用的一致");
        s.vault
            .materialize()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(stored_h)
    })
}

pub fn sync_date_shift_days(profile_key: Vec<u8>) -> anyhow::Result<i32> {
    Ok(sync::date_shift_days(&key32(&profile_key)?))
}

/// Argon2id KDF 真机基准(设置页/首次建号按结果调参数,不写死 `KDF_DEFAULT`)。
/// 参数合法性由 `argon2` crate 自己的下限把关(`Params::new`,`sync::kek_from_password`
/// 内部调用):`m_kib >= 8` 且 `m_kib >= 8 * p`,`t >= 1`,`1 <= p <= 0xFFFFFF`——
/// 不在这里另行 clamp/静默改写调用方传的参数,越界直接报错,不能悄悄跑出一个
/// "看起来很快"但根本没有真的按参数跑满的 ~0ms(旧版 `let _ = ...` 吞错的后果)。
pub fn sync_kdf_bench_ms(m_kib: u32, t: u32, p: u32) -> anyhow::Result<u64> {
    let t0 = std::time::Instant::now();
    sync::kek_from_password("bench", &[0u8; 16], &sync::KdfParams { m_kib, t, p })?;
    Ok(t0.elapsed().as_millis() as u64)
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

    /// 回归(review round 1 #1):`sync_open_profile_vault` 用错误的档案密钥
    /// 重开一个已经写过事件的真相目录时,`open_inner` 会因为 MAC 全部验不过而
    /// 认为日志是空的;若派生库(`medme.db`,同一 `truth_root` 下之前正确 key
    /// 打开时已经写出的缓存)还有行,就会走 `migrate_db_to_log` 从 DB 重新
    /// 合成一份日志——在磁盘上凭空多出一个设备段文件,真伪不分。必须在调用
    /// `Vault::open_split_resilient_with_key` 之前就拒绝,日志目录必须
    /// 一字节不动。
    #[test]
    fn wrong_key_reopen_is_rejected_and_never_mutates_the_log_dir() {
        let _guard = VAULT_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let pk = sync_profile_key_new();
        let home = tempdir().unwrap();
        sync_open_profile_vault(
            home.path().to_string_lossy().into(),
            home.path().join("data").to_string_lossy().into(),
            pk.clone(),
        )
        .unwrap();
        crate::api::vault::ingest_bytes("r.txt".into(), b"WBC 5.0".to_vec()).unwrap();

        let log_dir = home.path().join("vault").join("log");
        let snapshot = |dir: &std::path::Path| -> Vec<(std::ffi::OsString, Vec<u8>)> {
            let mut v: Vec<_> = std::fs::read_dir(dir)
                .unwrap()
                .filter_map(|e| e.ok())
                .map(|e| (e.file_name(), std::fs::read(e.path()).unwrap()))
                .collect();
            v.sort();
            v
        };
        let before = snapshot(&log_dir);
        assert!(!before.is_empty());

        let wrong_key = sync_profile_key_new();
        let result = sync_open_profile_vault(
            home.path().to_string_lossy().into(),
            home.path().join("data2").to_string_lossy().into(),
            wrong_key,
        );
        assert!(result.is_err(), "错误档案密钥必须被拒绝,不能悄悄打开");

        let after = snapshot(&log_dir);
        assert_eq!(
            before, after,
            "重开失败前后,日志目录必须一字节不动(不许多出合成段、不许改内容)"
        );
    }

    /// review round 2:`probe_key_mismatch` 的第一版把"从未被任何密钥封过的
    /// 纯 chain-only 日志"也判成了密钥不匹配——直接挡住了"已有的本机保险箱
    /// 第一次开云同步"这个受支持的升级路径(`open_vault` 打开、写过事件、
    /// 从未 keyed 过,现在第一次生成档案密钥、调 `sync_open_profile_vault`)。
    /// 必须能顺利升级,不多不少还是那一个设备段文件。
    #[test]
    fn first_time_key_upgrade_on_an_existing_local_vault_succeeds() {
        let _guard = VAULT_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempdir().unwrap();
        let docs_dir = home.path().join("docs");
        let data_dir = home.path().join("data");
        crate::api::vault::open_vault(
            docs_dir.to_string_lossy().to_string(),
            data_dir.to_string_lossy().to_string(),
            None,
        )
        .unwrap();
        crate::api::vault::ingest_bytes("r.txt".into(), b"WBC 5.0".to_vec()).unwrap();
        assert!(!sync_current_vault_is_keyed(), "普通 open_vault 打开的不是 keyed");

        let log_dir = docs_dir.join("vault").join("log");
        let segment_names = |dir: &std::path::Path| -> Vec<std::ffi::OsString> {
            let mut v: Vec<_> = std::fs::read_dir(dir)
                .unwrap()
                .filter_map(|e| e.ok())
                .map(|e| e.file_name())
                .collect();
            v.sort();
            v
        };
        let before = segment_names(&log_dir);
        assert_eq!(before.len(), 1, "本机 unkeyed vault 只有一个设备段");

        let fresh_key = sync_profile_key_new();
        sync_open_profile_vault(
            docs_dir.to_string_lossy().to_string(),
            data_dir.to_string_lossy().to_string(),
            fresh_key,
        )
        .unwrap();
        assert!(sync_current_vault_is_keyed(), "升级后应报告为 keyed");

        let after = segment_names(&log_dir);
        assert_eq!(before, after, "升级封 mac 不该多出/少掉任何段文件");
    }

    /// review round 1 #1(第二部分):`VaultState.profile_key` 要真被读——
    /// keyed 打开后为 true,切回普通 `open_vault`(unkeyed 路径,行为不变)后
    /// 应该翻回 false。
    #[test]
    fn current_vault_is_keyed_reflects_open_kind() {
        let _guard = VAULT_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let pk = sync_profile_key_new();
        let home = tempdir().unwrap();
        sync_open_profile_vault(
            home.path().to_string_lossy().into(),
            home.path().join("data").to_string_lossy().into(),
            pk,
        )
        .unwrap();
        assert!(sync_current_vault_is_keyed());

        let home2 = tempdir().unwrap();
        crate::api::vault::open_vault(
            home2.path().join("docs").to_string_lossy().to_string(),
            home2.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();
        assert!(!sync_current_vault_is_keyed());
    }

    /// review round 1 #2:一条(通过 MAC 校验的)合法事件仍可能携带格式不对的
    /// 哈希——`object_relpath` 拿它切片拼路径,短的/带 `..`、`/` 的字符串会
    /// panic 或逃出 `objects/`。这道闸必须先过。
    #[test]
    fn object_hash_from_event_rejects_malformed_hash() {
        let good = "a".repeat(64);
        let ok_event = core_model::Event::FileImported {
            content_hash: good.clone(),
            original_name: "x".into(),
            mime_type: "text/plain".into(),
            byte_size: 1,
            imported_at: "2024-01-01T00:00:00Z".into(),
        };
        assert_eq!(object_hash_from_event(&ok_event), Some(good));

        let bogus = core_model::Event::FileImported {
            content_hash: "../../etc/passwd".into(),
            original_name: "x".into(),
            mime_type: "text/plain".into(),
            byte_size: 1,
            imported_at: "2024-01-01T00:00:00Z".into(),
        };
        assert_eq!(object_hash_from_event(&bogus), None);

        let unrelated = core_model::Event::DocumentDeleted {
            source_file_hash: "b".repeat(64),
            deleted_at: "2024-01-01T00:00:00Z".into(),
        };
        assert_eq!(object_hash_from_event(&unrelated), None);
    }

    fn any_file_under(dir: &std::path::Path) -> bool {
        let Ok(rd) = std::fs::read_dir(dir) else {
            return false;
        };
        for entry in rd.filter_map(|e| e.ok()) {
            let p = entry.path();
            if p.is_dir() {
                if any_file_under(&p) {
                    return true;
                }
            } else if p.is_file() {
                return true;
            }
        }
        false
    }

    /// review round 1 #3:内容哈希算出的 `object_id` 跟传入的声称对不上时,
    /// `store_object` 一次都不能调用——校验必须先于落盘,`objects/` 下不该
    /// 出现任何文件。
    #[test]
    fn store_object_rejects_mismatched_object_id_without_touching_cas() {
        let _guard = VAULT_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let pk_bytes = sync_profile_key_new();
        let pk = key32(&pk_bytes).unwrap();
        let home = tempdir().unwrap();
        sync_open_profile_vault(
            home.path().to_string_lossy().into(),
            home.path().join("data").to_string_lossy().into(),
            pk_bytes.clone(),
        )
        .unwrap();

        // AAD = 声称的 object_id,解密本身会成功——但内容压根不是这个 id 对应
        // 的东西(真正的攻击面:AAD 只保证"没被换过密文",不保证"发件人没在
        // object_id 上撒谎")。
        let claimed_id = "claimed-id-does-not-match-content";
        let ct = sync::encrypt_blob(&pk, claimed_id, b"some object bytes").unwrap();
        let result = sync_store_object(pk_bytes, claimed_id.to_string(), ct);
        assert!(result.is_err(), "内容哈希算出的 object_id 应该跟声称的对不上");

        let objects_dir = home.path().join("vault").join("objects");
        assert!(
            !any_file_under(&objects_dir),
            "校验没过,不该在 objects/ 下写出任何文件"
        );
    }

    /// review round 1 #4:一批事件里,device A 中间那条解不开(密文损坏),
    /// device B 干净——B 应该全量落盘,A 只落到坏事件之前的那些,`undecodable`
    /// 记一次(不是把 A 后面没试过的也算进去)。
    #[test]
    fn import_events_applies_decodable_prefix_per_device_and_counts_undecodable() {
        let _guard = VAULT_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let pk = sync_profile_key_new();

        let a = tempdir().unwrap();
        sync_open_profile_vault(
            a.path().to_string_lossy().into(),
            a.path().join("data").to_string_lossy().into(),
            pk.clone(),
        )
        .unwrap();
        crate::api::vault::ingest_bytes("a1.txt".into(), b"WBC 5.0".to_vec()).unwrap();
        crate::api::vault::ingest_bytes("a2.txt".into(), b"RBC 4.5".to_vec()).unwrap();
        let mut events_a = sync_export_events(pk.clone(), vec![]).unwrap();
        events_a.sort_by_key(|e| e.seq);
        assert!(events_a.len() >= 3, "两次导入应产出至少 3 条事件");
        let corrupt_idx = 1; // 中间那条,不是第一条也不是最后一条
        let last_byte = events_a[corrupt_idx].ciphertext.len() - 1;
        events_a[corrupt_idx].ciphertext[last_byte] ^= 0x01;
        let device_a_id = events_a[0].device_id.clone();

        let b_src = tempdir().unwrap();
        sync_open_profile_vault(
            b_src.path().to_string_lossy().into(),
            b_src.path().join("data").to_string_lossy().into(),
            pk.clone(),
        )
        .unwrap();
        crate::api::vault::ingest_bytes("b1.txt".into(), b"HGB 130".to_vec()).unwrap();
        let events_b = sync_export_events(pk.clone(), vec![]).unwrap();
        assert!(!events_b.is_empty());
        let device_b_id = events_b[0].device_id.clone();

        let c = tempdir().unwrap();
        sync_open_profile_vault(
            c.path().to_string_lossy().into(),
            c.path().join("data").to_string_lossy().into(),
            pk.clone(),
        )
        .unwrap();

        let mut batch = events_a.clone();
        batch.extend(events_b.clone());
        let outcome = sync_import_events(pk.clone(), batch).unwrap();

        assert_eq!(outcome.undecodable, 1, "只有 A 那一条坏的算一次");
        assert_eq!(
            outcome.applied as usize,
            corrupt_idx + events_b.len(),
            "A 只应用到坏事件之前那些,B 全量应用"
        );

        let local_seq = sync_local_seq_map().unwrap();
        let seq_of = |dev: &str| -> i64 {
            local_seq
                .iter()
                .find(|(d, _)| d == dev)
                .map(|(_, s)| *s)
                .unwrap_or(0)
        };
        assert_eq!(
            seq_of(&device_a_id),
            events_a[corrupt_idx - 1].seq,
            "A 只落到坏事件之前那一条的 seq,后面的(即便本身没坏)一条都没试"
        );
        assert_eq!(
            seq_of(&device_b_id),
            events_b.last().unwrap().seq,
            "B 未受影响,全量落盘"
        );
    }

    #[test]
    fn kdf_bench_runs() {
        assert!(sync_kdf_bench_ms(8192, 1, 1).unwrap() < 5_000);
    }

    /// review round 1 #5:`m_kib` 低于 argon2 的下限(`m_kib >= 8`,且
    /// `m_kib >= 8 * p`)必须报错,不能被旧版 `let _ = ...` 悄悄吞掉、报回一个
    /// 看似"跑完了"的 ~0ms。
    #[test]
    fn kdf_bench_rejects_params_below_argons_floor() {
        assert!(sync_kdf_bench_ms(4, 1, 1).is_err(), "m_kib=4 < 下限 8");
        assert!(sync_kdf_bench_ms(8, 0, 1).is_err(), "t=0 非法");
        assert!(sync_kdf_bench_ms(8, 1, 0).is_err(), "p=0 非法");
        assert!(
            sync_kdf_bench_ms(8, 1, 2).is_err(),
            "m_kib(8) < 8*p(16),即便 m_kib 本身达到了 8"
        );
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
