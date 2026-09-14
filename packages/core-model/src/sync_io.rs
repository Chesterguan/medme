//! 云同步的日志/对象接口(子项目 B §3)。只做本地读写,不联网。
use crate::event::{Event, LogEntry};
use crate::{cas, MedmeError, Vault};
use std::collections::{HashMap, HashSet};

/// `append_peer_entries` 的分类计数,供调用方(FRB `vault_sync.rs` / Dart
/// `SyncEngine`)决定下一步:该往哪个水位继续拉、要不要对用户报错。
#[derive(Debug, Default, PartialEq)]
pub struct PeerAppendOutcome {
    /// 本次新写入本机磁盘的条数——只表示"写盘了",不代表通过了 MAC/链校验
    /// (校验结果见 `untrusted`)。
    pub applied: usize,
    /// 精确 `(device_id, seq)` 已经在磁盘上、本次原样跳过的条数。
    pub skipped_existing: usize,
    /// `seq` 落在该 device 段当前 tail 之下、但磁盘上并不存在这个确切 seq 的
    /// 条目——若写入会插在已有更高 seq 之后,打断按 seq 递增的链,因此拒绝写入。
    /// 调用方应把该 device 的拉取水位下调,重新从更低的 seq 开始拉。
    pub out_of_order: usize,
    /// 本次涉及的条目中,`(device_id, seq)` 在磁盘上存在(本次写入的,或之前已
    /// 存在的),但没有出现在 `read_all()`(通过 MAC/链校验)结果里的条数——
    /// 通常是错误的账号密钥或被篡改。`device_seq_map` 只反映**可信**水位,不会
    /// 把这些计入,所以调用方必须用这个字段发现"越推越推不动"的死循环,而不是
    /// 无限重推。
    pub untrusted: usize,
}

impl Vault {
    pub fn log_entries(&self) -> Result<Vec<LogEntry>, MedmeError> {
        self.log.read_all()
    }

    /// 每个 device 段**可信**的当前最大 seq(即通过了 MAC/链校验、`read_all()`
    /// 会返回的那些)。推送时把 `seq > 服务端水位` 的条目发出去;拉取时把
    /// `seq > 本机水位` 的条目要回来。
    ///
    /// 注意:这不是"磁盘上写了多少条"的水位——被隔离(错误密钥/篡改)的条目不
    /// 计入。调用方若只看这个水位就重推,永远重推不到的条目应改查
    /// `PeerAppendOutcome::untrusted`(见 `append_peer_entries`),而不是死循环。
    pub fn device_seq_map(&self) -> Result<HashMap<String, i64>, MedmeError> {
        let mut m = HashMap::new();
        for e in self.log.read_all()? {
            let cur = m.entry(e.device_id.clone()).or_insert(0);
            if e.seq > *cur {
                *cur = e.seq;
            }
        }
        Ok(m)
    }

    /// 追加别的设备的条目(按 device 段落盘)。条目原样落盘(见
    /// `EventLog::append_sealed`):`prev_hash`/`mac` 保留源设备当时用账号密钥封的
    /// 结果,不用本机 key 重新封——这样验证不了 MAC 的伪造/错误密钥条目会在
    /// `read_all` 时被隔离,而不是被本机悄悄"重新认证"成可信的。
    ///
    /// 去重按**精确** `(device_id, seq)` 是否已在磁盘上判断(而不是 `seq <= tail`
    /// ——那样会把"该 seq 从没落盘、只是恰好比某个更高 seq 小"误判成已存在,永久
    /// 丢掉这条)。**必须按 seq 升序传入**,否则链会断:一条 seq 低于该 device 段
    /// 当前 tail、但磁盘上确实不存在的条目会被计入 `out_of_order` 并拒绝写入
    /// (写入会插在更高 seq 之后,打断链),调用方应据此下调拉取水位重推。
    pub fn append_peer_entries(
        &self,
        entries: &[LogEntry],
    ) -> Result<PeerAppendOutcome, MedmeError> {
        let mut sorted: Vec<&LogEntry> = entries.iter().collect();
        sorted.sort_by(|a, b| (a.device_id.as_str(), a.seq).cmp(&(b.device_id.as_str(), b.seq)));

        let mut outcome = PeerAppendOutcome::default();
        let mut existing: HashMap<String, HashSet<i64>> = HashMap::new();

        for e in &sorted {
            if !existing.contains_key(&e.device_id) {
                let seqs = self.log.existing_seqs_of_device(&e.device_id)?;
                existing.insert(e.device_id.clone(), seqs);
            }
            // Just inserted above if absent, so this lookup always hits.
            let seqs = existing.get_mut(&e.device_id).expect("just inserted");
            if seqs.contains(&e.seq) {
                outcome.skipped_existing += 1;
                continue;
            }
            let tail = seqs.iter().copied().max().unwrap_or(0);
            if e.seq <= tail {
                // Exists-below-tail but not an exact match: writing it now would
                // land AFTER the higher seq already on disk and break the
                // per-segment chain. Reject; the caller should re-pull from a
                // lower watermark instead of silently losing this entry.
                outcome.out_of_order += 1;
                continue;
            }
            self.log.append_sealed(e)?;
            seqs.insert(e.seq);
            outcome.applied += 1;
        }

        if outcome.applied > 0 {
            self.materialize()?;
        }

        // `untrusted`: among the entries this call concerns, how many have their
        // (device_id, seq) sitting on disk (just written here, or already there
        // from an earlier call) yet never come back out of the AUTHENTICATED
        // `read_all()` — i.e. were sealed under a key/chain this vault's own key
        // can't verify. Computed against the full input (not just what THIS call
        // wrote) so a caller who keeps re-pushing already-quarantined entries
        // sees `untrusted` stay nonzero instead of silently seeing `applied: 0`
        // and assuming success.
        let trusted: HashSet<(String, i64)> = self
            .log
            .read_all()?
            .into_iter()
            .map(|e| (e.device_id, e.seq))
            .collect();
        let mut checked: HashSet<(String, i64)> = HashSet::new();
        for e in &sorted {
            let key = (e.device_id.clone(), e.seq);
            if !checked.insert(key.clone()) {
                continue; // duplicate entry within this same batch
            }
            let on_disk = existing
                .get(&e.device_id)
                .is_some_and(|s| s.contains(&e.seq));
            if on_disk && !trusted.contains(&key) {
                outcome.untrusted += 1;
            }
        }

        Ok(outcome)
    }

    /// 事件引用了、但 `objects/` 里还没有的对象哈希(拉对象的清单)。
    pub fn missing_object_hashes(&self) -> Result<Vec<String>, MedmeError> {
        let mut out = Vec::new();
        for e in self.log.read_all()? {
            let h = match &e.event {
                Event::FileImported { content_hash, .. } => content_hash,
                Event::OcrAdded { text_hash, .. } => text_hash,
                // 抽取结果的 JSON 也在 CAS 里,漏了这一支 = 抽取结果在第二台设备上
                // 永远 `Deferred`,而备份状态照样显示「已同步」(静默丢数据)。
                Event::ExtractionAdded { result_hash, .. } => result_hash,
                _ => continue,
            };
            if cas::is_object_hash(h)
                && !self.root().join(cas::object_relpath(h)).exists()
                && !out.contains(h)
            {
                out.push(h.clone());
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use crate::Vault;
    use tempfile::tempdir;

    fn keyed(dir: &std::path::Path, dev: &str) -> Vault {
        Vault::open_split_resilient_with_key(dir, &dir.join(format!("{dev}.db")), dev, &[9u8; 32])
            .unwrap()
    }

    #[test]
    fn peer_entries_apply_once_and_materialize() {
        let a = tempdir().unwrap();
        let b = tempdir().unwrap();
        let va = keyed(a.path(), "dev-a");
        va.import("r.txt", "text/plain", "血红蛋白 130 g/L".as_bytes())
            .unwrap();
        let entries = va.log_entries().unwrap();
        assert!(!entries.is_empty());

        let vb = keyed(b.path(), "dev-b");
        // 对象还没同步:先只推事件,materialize 必须容忍缺对象
        let out = vb.append_peer_entries(&entries).unwrap();
        assert_eq!(out.applied, entries.len());
        assert_eq!(out.skipped_existing, 0);
        assert_eq!(out.out_of_order, 0);
        assert_eq!(
            out.untrusted, 0,
            "same key on both sides, nothing quarantined"
        );

        let out2 = vb.append_peer_entries(&entries).unwrap();
        assert_eq!(out2.applied, 0, "重复推送不重复追加");
        assert_eq!(out2.skipped_existing, entries.len());

        let missing = vb.missing_object_hashes().unwrap();
        assert_eq!(missing.len(), 1);
        // 把对象搬过去后再 materialize 一次,文档出现
        let bytes = va.read_object(&missing[0]).unwrap();
        vb.store_object(&bytes).unwrap();
        vb.materialize().unwrap();
        assert!(vb.missing_object_hashes().unwrap().is_empty());
        assert_eq!(
            vb.device_seq_map()
                .unwrap()
                .get("dev-a")
                .copied()
                .unwrap_or(0),
            entries.len() as i64
        );

        // materialize 真的把投影建出来了(不只是 CAS 里有对象文件):B 上的
        // source_file 行数应该等于 A 上的,和 materialize.rs 现有测试同样用
        // `debug_count` 核对投影,而不是只看文件存在。
        assert_eq!(
            vb.debug_count("source_file"),
            va.debug_count("source_file"),
            "B 的投影(source_file)应与 A 一致"
        );
        assert_eq!(vb.debug_count("source_file"), 1);
    }

    #[test]
    fn out_of_order_entry_is_rejected_not_written() {
        let a = tempdir().unwrap();
        let b = tempdir().unwrap();
        let va = keyed(a.path(), "dev-a");
        va.import("1.txt", "text/plain", b"one").unwrap();
        va.import("2.txt", "text/plain", b"two").unwrap();
        va.import("3.txt", "text/plain", b"three").unwrap();
        let entries = va.log_entries().unwrap();
        assert_eq!(entries.len(), 3);
        assert_eq!((entries[0].seq, entries[1].seq, entries[2].seq), (1, 2, 3));

        let vb = keyed(b.path(), "dev-b");
        // 先送到 seq 1 和 3,扣住 seq 2(模拟网络乱序/丢包后先到的批次)。
        let first = vb
            .append_peer_entries(&[entries[0].clone(), entries[2].clone()])
            .unwrap();
        assert_eq!(first.applied, 2);

        // 再单独送 seq 2:它比磁盘上已有的 tail(3)低,但磁盘上并没有这个确切
        // seq——写进去会插在 seq 3 后面、打断按 seq 递增的链,必须拒绝。
        let second = vb
            .append_peer_entries(std::slice::from_ref(&entries[1]))
            .unwrap();
        assert_eq!(second.out_of_order, 1);
        assert_eq!(second.applied, 0);
        assert_eq!(second.skipped_existing, 0);

        // seq 2 确实没有落盘:既不在可信读取里,也不在该 device 段的原始行数里。
        assert!(vb
            .log_entries()
            .unwrap()
            .iter()
            .all(|e| e.seq != entries[1].seq));
        let raw = std::fs::read_to_string(b.path().join("log/dev-a-000001.jsonl")).unwrap();
        assert_eq!(
            raw.lines().count(),
            2,
            "segment 上只有 seq 1、3 两行,seq 2 没写进去"
        );
    }

    #[test]
    fn wrong_key_peer_entries_are_quarantined() {
        let a = tempdir().unwrap();
        let b = tempdir().unwrap();
        let va = keyed(a.path(), "dev-a");
        va.import("r.txt", "text/plain", b"x").unwrap();
        let entries = va.log_entries().unwrap();
        let vb = Vault::open_split_resilient_with_key(
            b.path(),
            &b.path().join("b.db"),
            "dev-b",
            &[1u8; 32],
        )
        .unwrap();

        let first = vb.append_peer_entries(&entries).unwrap();
        // 写盘成功(原样落盘,不看本机 key),但本机 key 验不过源设备的 MAC。
        assert_eq!(first.applied, entries.len());
        assert_eq!(first.untrusted, entries.len());
        // MAC 用的是 a 的 key,b 用另一把 key 验证不过 → read_all 隔离 → 看不到
        assert!(vb
            .log_entries()
            .unwrap()
            .iter()
            .all(|e| e.device_id != "dev-a"));

        // 重推同一批:精确 (device_id, seq) 已在磁盘上,按存在跳过——但仍然不可
        // 信,`untrusted` 必须继续反映出来,而不是看起来像"已同步"。
        let second = vb.append_peer_entries(&entries).unwrap();
        assert_eq!(second.applied, 0);
        assert_eq!(second.skipped_existing, entries.len());
        assert_eq!(second.untrusted, entries.len());
    }

    /// 抽取结果的 CAS 对象必须和原件、OCR 文本一样进同步清单。
    ///
    /// 漏掉这一支的后果是**静默丢数据**:事件本身推拉验 MAC 全都正常,
    /// `missing_object_hashes` 却不列 `result_hash`,于是备份状态显示「已同步」,
    /// 而对端 `materialize` 永远停在 `Deferred`——第二台设备/换机恢复之后
    /// `extraction` 表是空的,抽取结果全丢。所以这条测试**只走同步引擎的口径**
    /// (`missing_object_hashes`),绝不手工 copy 对象。
    #[test]
    fn extraction_object_is_enumerated_and_materializes_on_peer() {
        use crate::{DocType, NewDocument, NewExtraction};

        let a = tempdir().unwrap();
        let b = tempdir().unwrap();
        let va = keyed(a.path(), "dev-a");
        let imp = va
            .import("r.txt", "text/plain", "血红蛋白 130 g/L".as_bytes())
            .unwrap();
        let doc_id = va
            .add_document(NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: DocType::LabReport,
                doc_date: None,
                doc_date_end: None,
                title: Some("r.txt".into()),
                language: None,
                page_count: 1,
            })
            .unwrap()
            .id;
        va.add_extraction(NewExtraction {
            document_id: doc_id,
            backend: "cloud".into(),
            model_version: "deepseek-flash".into(),
            mode: "image".into(),
            result_json: r#"{"labs":[{"name":"血红蛋白","value":"130","unit":"g/L"}]}"#.into(),
        })
        .unwrap();

        let vb = keyed(b.path(), "dev-b");
        let entries = va.log_entries().unwrap();
        let out = vb.append_peer_entries(&entries).unwrap();
        assert_eq!(out.applied, entries.len());
        assert_eq!(out.untrusted, 0);

        // 按同步引擎的口径搬对象:`missing_object_hashes` 是唯一的待拉清单。
        for _ in 0..4 {
            let missing = vb.missing_object_hashes().unwrap();
            if missing.is_empty() {
                break;
            }
            for h in missing {
                let bytes = va.read_object(&h).unwrap();
                vb.store_object(&bytes).unwrap();
            }
            vb.materialize().unwrap();
        }
        assert!(
            vb.missing_object_hashes().unwrap().is_empty(),
            "清单搬完之后不该还有缺的对象"
        );

        let doc_b = vb.standalone_documents().unwrap()[0].id;
        assert_eq!(
            vb.extraction_json(doc_b).unwrap(),
            va.extraction_json(doc_id).unwrap(),
            "ExtractionAdded 应在第二台设备上 materialize 成 extraction 行"
        );
        assert!(vb.extraction_json(doc_b).unwrap().is_some());
    }
}
