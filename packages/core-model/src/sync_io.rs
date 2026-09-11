//! 云同步的日志/对象接口(子项目 B §3)。只做本地读写,不联网。
use crate::event::{Event, LogEntry};
use crate::{cas, MedmeError, Vault};
use std::collections::HashMap;

impl Vault {
    pub fn log_entries(&self) -> Result<Vec<LogEntry>, MedmeError> {
        self.log.read_all()
    }

    /// 每个 device 段的当前最大 seq。推送时把 `seq > 服务端水位` 的条目发出去;
    /// 拉取时把 `seq > 本机水位` 的条目要回来。
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
    /// 已有的 `(device_id, seq)` 跳过。**必须按 seq 升序传入**,否则链会断。
    pub fn append_peer_entries(&self, entries: &[LogEntry]) -> Result<usize, MedmeError> {
        let mut sorted: Vec<&LogEntry> = entries.iter().collect();
        sorted.sort_by(|a, b| (a.device_id.as_str(), a.seq).cmp(&(b.device_id.as_str(), b.seq)));
        let mut tails: HashMap<String, i64> = HashMap::new();
        let mut n = 0;
        for e in sorted {
            let tail = match tails.get(&e.device_id) {
                Some(t) => *t,
                None => {
                    let t = self.log.tail_seq_of_device(&e.device_id)?;
                    tails.insert(e.device_id.clone(), t);
                    t
                }
            };
            if e.seq <= tail {
                continue;
            }
            self.log.append_sealed(e)?;
            tails.insert(e.device_id.clone(), e.seq);
            n += 1;
        }
        if n > 0 {
            self.materialize()?;
        }
        Ok(n)
    }

    /// 事件引用了、但 `objects/` 里还没有的对象哈希(拉对象的清单)。
    pub fn missing_object_hashes(&self) -> Result<Vec<String>, MedmeError> {
        let mut out = Vec::new();
        for e in self.log.read_all()? {
            let h = match &e.event {
                Event::FileImported { content_hash, .. } => content_hash,
                Event::OcrAdded { text_hash, .. } => text_hash,
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
        assert_eq!(vb.append_peer_entries(&entries).unwrap(), entries.len());
        assert_eq!(
            vb.append_peer_entries(&entries).unwrap(),
            0,
            "重复推送不重复追加"
        );
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
        vb.append_peer_entries(&entries).unwrap();
        // MAC 用的是 a 的 key,b 用另一把 key 验证不过 → read_all 隔离 → 看不到
        assert!(vb
            .log_entries()
            .unwrap()
            .iter()
            .all(|e| e.device_id != "dev-a"));
    }
}
