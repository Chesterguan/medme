//! Append-only JSONL event log under `<vault>/log/`, segmented per device.
//!
//! Each device appends **only to its own segment** `log/<device_id>-000001.jsonl`
//! (one `LogEntry` per line), so multiple devices sharing a cloud-synced vault
//! never write the same file → no write conflicts (see `docs/013_Mobile_App.md`
//! §3, §6). A pre-refactor vault's single `log/000001.jsonl` is picked up as
//! just one more segment — no migration needed.
//!
//! `read_all` scans **all** `*.jsonl` segments (every device's + any legacy
//! one) and merges them into a single **deterministic global order**: by event
//! timestamp, tie-broken by `(device_id, seq)`. Because the log is append-only
//! and each entity is content-hash/uuid keyed (created once), replaying this
//! merged set reproduces a consistent state regardless of how many devices
//! contributed or in what filesystem order the segments were enumerated.

use crate::event::{LogEntry, GENESIS_HASH};
use crate::MedmeError;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use tempfile::NamedTempFile;

pub struct EventLog {
    dir: PathBuf,
    /// Per-vault 32-byte secret used to HMAC every appended entry and to verify
    /// entries on read. `None` = chain-only mode (no MAC): entries are still
    /// chained (`prev_hash`), but that chain is a KEYLESS sha256, so it detects
    /// only NON-ADVERSARIAL corruption (bit rot / torn writes). A folder-writing
    /// adversary can insert/delete/reorder and simply RECOMPUTE the whole
    /// segment's `prev_hash` chain from genesis — every chain check then passes
    /// with no break logged. Only the keyed MAC gives real tamper/forgery
    /// detection. Injected by `Vault` via [`EventLog::set_key`]; keychain
    /// storage + QR distribution of this key is an app-layer follow-up.
    key: Option<Vec<u8>>,
}

impl EventLog {
    pub fn open(vault_root: &Path) -> Result<Self, MedmeError> {
        let dir = vault_root.join("log");
        std::fs::create_dir_all(&dir)?;
        Ok(EventLog { dir, key: None })
    }

    /// Inject (or clear) the per-vault MAC key. Must be set BEFORE the open-time
    /// migration/materialize so legacy entries are sealed with a MAC and the
    /// first replay verifies with the key. See [`crate::Vault::open_with_key`].
    pub(crate) fn set_key(&mut self, key: Option<Vec<u8>>) {
        self.key = key;
    }

    /// All `.jsonl` segment files in the log dir: every device's per-device
    /// segment plus any legacy single `000001.jsonl`. Order is irrelevant —
    /// `read_all` sorts events globally — but we sort by name for stable I/O.
    fn segments(&self) -> Result<Vec<PathBuf>, MedmeError> {
        let mut files: Vec<PathBuf> = std::fs::read_dir(&self.dir)?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("jsonl"))
            .collect();
        files.sort();
        Ok(files)
    }

    /// The segment this device appends to. New events from a device go to its
    /// own file, so two devices never contend for the same segment.
    fn device_segment(&self, device_id: &str) -> PathBuf {
        self.dir.join(format!("{device_id}-000001.jsonl"))
    }

    /// Append one event line to the appending device's own segment (keyed by
    /// `entry.device_id`), creating it on first write. The entry is SEALED here:
    /// its `prev_hash` is chained to the segment's current tail and its `mac` is
    /// computed under the vault key (when set), so what lands on disk is always
    /// tamper-evident and authenticated.
    pub fn append(&self, entry: &LogEntry) -> Result<(), MedmeError> {
        let path = self.device_segment(&entry.device_id);
        // Chain this entry to the last one already in ITS OWN segment. Appends
        // to a device's segment are strictly ordered (single writer, monotonic
        // seq), so file order == chain order.
        let prev_hash = self.segment_tail_hash(&path)?;
        let mut sealed = entry.clone();
        sealed.seal(prev_hash, self.key.as_deref())?;

        let mut f = OpenOptions::new().create(true).append(true).open(&path)?;
        let line = serde_json::to_string(&sealed)?;
        writeln!(f, "{line}")?;
        f.flush()?;
        // Durability: fsync the appended line so a "saved" event survives power
        // loss before we return success (medical data — silent loss is fatal).
        f.sync_all()?;
        Ok(())
    }

    /// Chain hash of the last entry currently in `path` — the `prev_hash` the
    /// next appended entry must carry. `GENESIS_HASH` when the segment is
    /// absent/empty (a fresh chain) or its tail can't be parsed (a truncated
    /// last line is ignored; the new entry starts a fresh link from genesis so
    /// the append never fails on a corrupt tail).
    fn segment_tail_hash(&self, path: &Path) -> Result<String, MedmeError> {
        if !path.exists() {
            return Ok(GENESIS_HASH.to_string());
        }
        match read_segment_entries(path)?.last() {
            Some(tail) => tail.chain_hash(),
            None => Ok(GENESIS_HASH.to_string()),
        }
    }

    /// All *trusted* events across every segment, merged into a deterministic
    /// global order: primarily by timestamp, tie-broken by `(device_id, seq)`.
    /// This order is independent of filesystem enumeration, so any device
    /// rebuilds to the identical state from the same set of segments.
    ///
    /// Each segment is verified BEFORE the merge (the chain is per-segment):
    /// entries with a failing MAC (forged/tampered) and entries after a
    /// hash-chain break (insert/delete/reorder) are QUARANTINED — skipped and
    /// logged, never returned to callers, so a shared-folder attacker's writes
    /// can't poison the replay. A break never aborts the open: the valid prefix
    /// of every segment still materializes.
    pub fn read_all(&self) -> Result<Vec<LogEntry>, MedmeError> {
        let mut out: Vec<LogEntry> = Vec::new();
        for path in self.segments()? {
            let entries = read_segment_entries(&path)?;
            let seg = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("<segment>");
            out.extend(self.verify_segment(entries, seg));
        }
        out.sort_by(|a, b| {
            a.ts.cmp(&b.ts)
                .then_with(|| a.device_id.cmp(&b.device_id))
                .then_with(|| a.seq.cmp(&b.seq))
        });
        Ok(out)
    }

    /// Verify one segment's entries (already in file/append order) and return
    /// only the trusted ones. Two independent checks:
    ///
    /// - **MAC** (only when a key is set): recompute the HMAC over each entry's
    ///   canonical bytes; a mismatch/absence means the entry was forged or
    ///   tampered → quarantine it. A valid MAC proves the entry (including its
    ///   `prev_hash`) is exactly as the key holder wrote it.
    /// - **Chain**: each entry's `prev_hash` must equal the running chain hash.
    ///   A mismatch is a structural attack (insert/delete/reorder) → quarantine
    ///   and re-synchronise: the NEXT authentic (MAC-valid) entry is accepted on
    ///   its own authority and the chain resumes from it. This localises damage
    ///   — one tampered entry in the middle doesn't discard the authentic
    ///   entries after it (each still carries a valid MAC) — while every break
    ///   is still reported.
    ///
    /// With no key (chain-only fallback) only the chain is checked, and the
    /// chain is KEYLESS — it catches bit rot / torn writes, NOT an adversary. A
    /// folder-writing attacker can insert/delete/reorder AND recompute every
    /// `prev_hash` from genesis, so the whole segment re-verifies clean with no
    /// break logged. Chain-only is corruption-detection, not authentication:
    /// only the MAC (a key) provides real tamper/forgery detection.
    fn verify_segment(&self, entries: Vec<LogEntry>, seg: &str) -> Vec<LogEntry> {
        let key = self.key.as_deref();
        let mut kept: Vec<LogEntry> = Vec::with_capacity(entries.len());
        // Some(h) = the chain hash the next entry must reference; None = we are
        // re-syncing after a break and will accept the next authentic entry.
        let mut expected_prev: Option<String> = Some(GENESIS_HASH.to_string());

        for entry in entries {
            // 1) Authenticate the entry itself (skipped in chain-only mode).
            if let Some(k) = key {
                let ok = entry.verify_mac(k).unwrap_or(false);
                if !ok {
                    eprintln!(
                        "[log] quarantine seq={} in {seg}: MAC verification failed (forged/tampered)",
                        entry.seq
                    );
                    // Its bytes are untrusted → can't extend the chain from it.
                    expected_prev = None;
                    continue;
                }
            }
            // 2) Check the structural chain link.
            let this_prev = entry
                .prev_hash
                .clone()
                .unwrap_or_else(|| GENESIS_HASH.to_string());
            match &expected_prev {
                // Re-syncing after a break: accept this (MAC-authentic) entry
                // and resume the chain from it.
                None => {}
                Some(exp) if &this_prev == exp => {}
                Some(_) => {
                    eprintln!(
                        "[log] quarantine seq={} in {seg}: hash-chain break (insert/delete/reorder)",
                        entry.seq
                    );
                    expected_prev = None;
                    continue;
                }
            }
            // Accepted: advance the chain and keep it.
            expected_prev = match entry.chain_hash() {
                Ok(h) => Some(h),
                Err(e) => {
                    eprintln!("[log] chain_hash error for seq={} in {seg}: {e}", entry.seq);
                    None
                }
            };
            kept.push(entry);
        }
        kept
    }

    /// One-time, idempotent migration that seals legacy entries. Existing
    /// vaults have entries with no `prev_hash`/`mac`; here we treat those
    /// on-disk entries as TRUSTED-LOCAL (they predate sync / the attack model),
    /// recompute the `prev_hash` chain from genesis in append order, add the
    /// `mac` under the vault key (if set), and rewrite each segment ONCE
    /// (atomic temp-file + rename). Runs before the first replay so the log is
    /// authenticated from then on.
    ///
    /// Idempotent: a segment whose entries already carry a `prev_hash` (and a
    /// `mac`, when a key is present) is left untouched, and because the chain is
    /// recomputed deterministically, re-running reproduces byte-identical lines.
    pub(crate) fn migrate_and_seal(&self) -> Result<(), MedmeError> {
        let key = self.key.as_deref();
        for path in self.segments()? {
            // Migration REWRITES the segment from the lines it parses, so unlike
            // `read_all` it must never silently drop a line it can't parse: doing
            // so would permanently lose (e.g.) a forward-compat entry written by a
            // newer binary. A torn/incomplete FINAL line is skippable (it was
            // never a completed append); an unparseable NON-final line aborts the
            // migration of this segment, leaving the file byte-for-byte untouched.
            let entries = match read_segment_for_migration(&path)? {
                MigrationParse::Ok(entries) => entries,
                MigrationParse::AbortUnparsableLine => continue,
            };
            if entries.is_empty() {
                continue;
            }
            // Needs sealing if any entry lacks a chain link, or lacks a MAC
            // while we now hold a key (chain-only → keyed upgrade).
            let needs = entries
                .iter()
                .any(|e| e.prev_hash.is_none() || (key.is_some() && e.mac.is_none()));
            if !needs {
                continue;
            }
            let mut prev = GENESIS_HASH.to_string();
            let mut lines: Vec<String> = Vec::with_capacity(entries.len());
            for mut e in entries {
                e.seal(prev, key)?;
                prev = e.chain_hash()?;
                lines.push(serde_json::to_string(&e)?);
            }
            let parent = path.parent().ok_or_else(|| {
                MedmeError::Io(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "log segment path has no parent directory",
                ))
            })?;
            let mut tmp = NamedTempFile::new_in(parent)?;
            for line in &lines {
                writeln!(tmp, "{line}")?;
            }
            // Durability: fsync bytes before the atomic rename, then fsync the
            // dir so the replace survives power loss (same discipline as CAS).
            tmp.as_file().sync_all()?;
            tmp.persist(&path).map_err(|e| MedmeError::Io(e.error))?;
            std::fs::File::open(parent)?.sync_all()?;
        }
        Ok(())
    }

    pub fn is_empty(&self) -> Result<bool, MedmeError> {
        Ok(self.segments()?.is_empty() || self.read_all()?.is_empty())
    }

    pub fn max_seq(&self) -> Result<i64, MedmeError> {
        Ok(self.read_all()?.iter().map(|e| e.seq).max().unwrap_or(0))
    }
}

/// Parse a segment file into entries in FILE (append) order. Empty lines are
/// skipped; an unparseable line (e.g. a torn last write, or a maliciously
/// corrupted line) is skipped with a warning rather than aborting the read —
/// the surrounding chain/MAC verification then decides what to trust.
fn read_segment_entries(path: &Path) -> Result<Vec<LogEntry>, MedmeError> {
    let f = std::fs::File::open(path)?;
    let mut out: Vec<LogEntry> = Vec::new();
    for line in BufReader::new(f).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<LogEntry>(&line) {
            Ok(e) => out.push(e),
            Err(e) => eprintln!("[log] skip unparseable entry in {}: {e}", path.display()),
        }
    }
    Ok(out)
}

/// Outcome of parsing a segment for MIGRATION, which (unlike `read_all`) rewrites
/// the file and therefore must not silently drop any line.
enum MigrationParse {
    /// Every NON-final line parsed; these entries are safe to reseal + rewrite.
    /// A torn/incomplete FINAL line, if present, was skipped — it was never a
    /// completed append.
    Ok(Vec<LogEntry>),
    /// A NON-final line failed to parse (e.g. a forward-compat entry from a newer
    /// binary). Rewriting the segment would permanently drop it, so migration of
    /// this segment must abort and leave the file byte-unchanged.
    AbortUnparsableLine,
}

/// Parse a segment for migration. Non-empty lines are parsed in file order; the
/// LAST non-empty line is allowed to be unparseable (a torn final write) and is
/// skipped, but any EARLIER unparseable line aborts (returns
/// [`MigrationParse::AbortUnparsableLine`]) so the caller leaves the segment
/// untouched rather than dropping data.
fn read_segment_for_migration(path: &Path) -> Result<MigrationParse, MedmeError> {
    let f = std::fs::File::open(path)?;
    // Collect non-empty lines up front so we can tell whether an unparseable line
    // is the FINAL one (torn write — skippable) or an interior one (would be
    // dropped on rewrite — must abort).
    let raw: Vec<String> = BufReader::new(f)
        .lines()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|l| !l.trim().is_empty())
        .collect();
    let last = raw.len();
    let mut out: Vec<LogEntry> = Vec::with_capacity(last);
    for (i, line) in raw.iter().enumerate() {
        match serde_json::from_str::<LogEntry>(line) {
            Ok(e) => out.push(e),
            Err(e) => {
                if i + 1 == last {
                    // Torn/incomplete final line: never a completed append — skip.
                    eprintln!(
                        "[log] migrate: skip torn final line in {}: {e}",
                        path.display()
                    );
                } else {
                    // Interior unparseable line: rewriting would drop it. Abort so
                    // the segment is left untouched and nothing is lost.
                    eprintln!(
                        "[log] migrate: ABORT sealing {} — unparseable non-final line at index {i}: {e}",
                        path.display()
                    );
                    return Ok(MigrationParse::AbortUnparsableLine);
                }
            }
        }
    }
    Ok(MigrationParse::Ok(out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::Event;

    fn mk(seq: i64) -> LogEntry {
        mk_on("dev1", seq, "2024-01-01T00:00:00Z")
    }

    fn mk_on(device: &str, seq: i64, ts: &str) -> LogEntry {
        LogEntry::new(
            seq,
            ts.into(),
            device.into(),
            Event::FileImported {
                content_hash: format!("{device}-h{seq}"),
                original_name: "a".into(),
                mime_type: "text/plain".into(),
                byte_size: 1,
                imported_at: ts.into(),
            },
        )
        .unwrap()
    }

    #[test]
    fn append_and_read_all_round_trips_in_order() {
        let dir = tempfile::tempdir().unwrap();
        let log = EventLog::open(dir.path()).unwrap();
        assert!(log.is_empty().unwrap());

        log.append(&mk(1)).unwrap();
        log.append(&mk(2)).unwrap();

        let events = log.read_all().unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].seq, 1);
        assert_eq!(events[1].seq, 2);
        assert_eq!(log.max_seq().unwrap(), 2);
        assert!(!log.is_empty().unwrap());
    }

    #[test]
    fn reopen_appends_to_existing_segment() {
        let dir = tempfile::tempdir().unwrap();
        {
            let log = EventLog::open(dir.path()).unwrap();
            log.append(&mk(1)).unwrap();
        }
        let log2 = EventLog::open(dir.path()).unwrap();
        log2.append(&mk(2)).unwrap();
        assert_eq!(log2.read_all().unwrap().len(), 2);
    }

    #[test]
    fn append_writes_to_per_device_segment() {
        let dir = tempfile::tempdir().unwrap();
        let log = EventLog::open(dir.path()).unwrap();
        log.append(&mk_on("devA", 1, "2024-01-01T00:00:00Z"))
            .unwrap();
        log.append(&mk_on("devB", 1, "2024-01-01T00:00:01Z"))
            .unwrap();

        assert!(dir.path().join("log/devA-000001.jsonl").is_file());
        assert!(dir.path().join("log/devB-000001.jsonl").is_file());
        // Each device wrote only its own segment; no shared/legacy file created.
        assert!(!dir.path().join("log/000001.jsonl").exists());
        assert_eq!(log.read_all().unwrap().len(), 2);
    }

    #[test]
    fn read_all_merges_segments_in_deterministic_ts_order_not_filename_order() {
        let dir = tempfile::tempdir().unwrap();
        let log_dir = dir.path().join("log");
        std::fs::create_dir_all(&log_dir).unwrap();

        // Two segments whose filename alpha order (aaa < zzz) is the OPPOSITE
        // of their events' timestamp order — so name-order concatenation would
        // misorder them; the (ts, device_id, seq) sort must not.
        let e_late = mk_on("zzz", 1, "2024-06-01T00:00:00Z");
        let e_early = mk_on("aaa", 1, "2024-01-01T00:00:00Z");
        std::fs::write(
            log_dir.join("zzz-000001.jsonl"),
            format!("{}\n", serde_json::to_string(&e_late).unwrap()),
        )
        .unwrap();
        std::fs::write(
            log_dir.join("aaa-000001.jsonl"),
            format!("{}\n", serde_json::to_string(&e_early).unwrap()),
        )
        .unwrap();

        let log = EventLog::open(dir.path()).unwrap();
        let events = log.read_all().unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(
            events[0].ts, "2024-01-01T00:00:00Z",
            "earlier ts sorts first"
        );
        assert_eq!(events[1].ts, "2024-06-01T00:00:00Z");
    }

    #[test]
    fn legacy_single_log_is_picked_up_as_one_segment() {
        let dir = tempfile::tempdir().unwrap();
        let log_dir = dir.path().join("log");
        std::fs::create_dir_all(&log_dir).unwrap();
        // A pre-refactor vault: one plain, non-namespaced segment file.
        let e = mk_on("legacydev", 1, "2023-01-01T00:00:00Z");
        std::fs::write(
            log_dir.join("000001.jsonl"),
            format!("{}\n", serde_json::to_string(&e).unwrap()),
        )
        .unwrap();

        let log = EventLog::open(dir.path()).unwrap();
        assert!(!log.is_empty().unwrap());
        let events = log.read_all().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].device_id, "legacydev");
    }

    // ---- tamper-evidence / authentication (advisory GHSA-m96x) --------------

    const KEY: &[u8] = &[7u8; 32];

    /// A keyed log open at `dir`. Distinct timestamps keep `read_all`'s global
    /// sort equal to append order so assertions on order are stable.
    fn keyed_log(dir: &Path) -> EventLog {
        let mut log = EventLog::open(dir).unwrap();
        log.set_key(Some(KEY.to_vec()));
        log
    }

    fn append_n(log: &EventLog, n: i64) {
        for seq in 1..=n {
            let ts = format!("2024-01-01T00:00:{:02}Z", seq);
            log.append(&mk_on("dev1", seq, &ts)).unwrap();
        }
    }

    fn seg_path(dir: &Path) -> PathBuf {
        dir.join("log/dev1-000001.jsonl")
    }

    fn read_lines(p: &Path) -> Vec<String> {
        std::fs::read_to_string(p)
            .unwrap()
            .lines()
            .map(|s| s.to_string())
            .collect()
    }

    fn write_lines(p: &Path, lines: &[String]) {
        std::fs::write(p, format!("{}\n", lines.join("\n"))).unwrap();
    }

    #[test]
    fn keyed_round_trip_appends_verify_clean() {
        let dir = tempfile::tempdir().unwrap();
        let log = keyed_log(dir.path());
        append_n(&log, 4);

        let events = log.read_all().unwrap();
        assert_eq!(events.len(), 4, "all entries verify and are returned");
        for (i, e) in events.iter().enumerate() {
            assert_eq!(e.seq, i as i64 + 1);
            assert!(e.mac.is_some(), "each appended entry is MAC'd");
            assert!(e.prev_hash.is_some(), "each appended entry is chained");
            assert!(e.verify_mac(KEY).unwrap());
        }
        // First entry chains to genesis; each subsequent to its predecessor.
        assert_eq!(events[0].prev_hash.as_deref(), Some(GENESIS_HASH));
        assert_eq!(
            events[1].prev_hash.as_deref().unwrap(),
            events[0].chain_hash().unwrap()
        );
    }

    #[test]
    fn tampered_entry_is_quarantined_others_survive() {
        let dir = tempfile::tempdir().unwrap();
        let log = keyed_log(dir.path());
        append_n(&log, 3);

        // Flip a byte in the MIDDLE entry's event body (change original_name).
        let mut lines = read_lines(&seg_path(dir.path()));
        let mut v: serde_json::Value = serde_json::from_str(&lines[1]).unwrap();
        v["original_name"] = serde_json::Value::String("TAMPERED".into());
        lines[1] = serde_json::to_string(&v).unwrap();
        write_lines(&seg_path(dir.path()), &lines);

        // The tampered entry (seq 2) is excluded; seq 1 and 3 survive (seq 3 is
        // MAC-authentic, so the chain re-synchronises to it). Open succeeds.
        let events = log.read_all().unwrap();
        let seqs: Vec<i64> = events.iter().map(|e| e.seq).collect();
        assert_eq!(seqs, vec![1, 3], "tampered entry quarantined, others kept");
    }

    #[test]
    fn forged_entry_without_valid_mac_is_excluded() {
        let dir = tempfile::tempdir().unwrap();
        let log = keyed_log(dir.path());
        append_n(&log, 2);

        // Append a forged line with a plausible body but no / bogus MAC — as a
        // shared-folder writer WITHOUT the key could only produce.
        let mut lines = read_lines(&seg_path(dir.path()));
        let mut forged = mk_on("dev1", 3, "2024-01-01T00:00:03Z");
        forged.prev_hash = Some(GENESIS_HASH.to_string());
        forged.mac = None;
        lines.push(serde_json::to_string(&forged).unwrap());
        let mut forged2 = mk_on("dev1", 4, "2024-01-01T00:00:04Z");
        forged2.prev_hash = Some(GENESIS_HASH.to_string());
        forged2.mac = Some("deadbeef".into()); // wrong MAC
        lines.push(serde_json::to_string(&forged2).unwrap());
        write_lines(&seg_path(dir.path()), &lines);

        let events = log.read_all().unwrap();
        let seqs: Vec<i64> = events.iter().map(|e| e.seq).collect();
        assert_eq!(seqs, vec![1, 2], "forged entries excluded, authentic kept");
    }

    #[test]
    fn deleted_entry_breaks_chain_valid_prefix_survives() {
        let dir = tempfile::tempdir().unwrap();
        let log = keyed_log(dir.path());
        append_n(&log, 4);

        // Delete the third entry (index 2). The chain breaks at what follows.
        let mut lines = read_lines(&seg_path(dir.path()));
        lines.remove(2);
        write_lines(&seg_path(dir.path()), &lines);

        // Open still succeeds; the valid prefix [1,2] survives, the deletion is
        // detected (seq 4, whose prev_hash no longer links, is quarantined).
        let events = log.read_all().unwrap();
        let seqs: Vec<i64> = events.iter().map(|e| e.seq).collect();
        assert_eq!(seqs, vec![1, 2], "valid prefix survives a mid-log deletion");
    }

    #[test]
    fn reordered_entries_break_chain_and_are_reported() {
        let dir = tempfile::tempdir().unwrap();
        let log = keyed_log(dir.path());
        append_n(&log, 4);

        // Swap entries 2 and 3 (indices 1 and 2) — each still has a valid MAC,
        // so only the chain can catch the reorder.
        let mut lines = read_lines(&seg_path(dir.path()));
        lines.swap(1, 2);
        write_lines(&seg_path(dir.path()), &lines);

        let events = log.read_all().unwrap();
        // seq 1 (genesis) and the resync'd first-out-of-order entry survive; the
        // reorder is detected (fewer than 4 returned) and open does not abort.
        assert!(
            events.len() < 4,
            "reorder detected: some entries quarantined, got {events:?}"
        );
        assert_eq!(events[0].seq, 1, "genesis entry always survives");
    }

    #[test]
    fn truncated_last_line_is_skipped_and_prefix_opens() {
        let dir = tempfile::tempdir().unwrap();
        let log = keyed_log(dir.path());
        append_n(&log, 3);

        // Simulate a torn final write: chop the last line in half.
        let mut lines = read_lines(&seg_path(dir.path()));
        let last = lines.last_mut().unwrap();
        *last = last[..last.len() / 2].to_string();
        write_lines(&seg_path(dir.path()), &lines);

        // Open succeeds on the intact prefix; the torn line is skipped, no panic.
        let events = log.read_all().unwrap();
        let seqs: Vec<i64> = events.iter().map(|e| e.seq).collect();
        assert_eq!(seqs, vec![1, 2], "torn tail skipped, valid prefix opens");
    }

    #[test]
    fn chain_only_mode_still_detects_reorder() {
        // No key set → chain-only fallback: content isn't authenticated, but the
        // structural chain still flags a reorder.
        let dir = tempfile::tempdir().unwrap();
        let log = EventLog::open(dir.path()).unwrap(); // no key
        append_n(&log, 3);
        // Entries are chained but unauthenticated (no MAC).
        assert!(read_lines(&seg_path(dir.path()))
            .iter()
            .all(|l| l.contains("prev_hash")));

        let mut lines = read_lines(&seg_path(dir.path()));
        lines.swap(1, 2);
        write_lines(&seg_path(dir.path()), &lines);

        let events = log.read_all().unwrap();
        assert!(
            events.len() < 3,
            "chain-only mode still detects the reorder"
        );
    }

    #[test]
    fn chain_only_mode_is_defeated_by_an_adversary_who_recomputes_the_chain() {
        // Honesty check for the chain-only wording: the keyless `prev_hash` chain
        // only catches non-adversarial corruption. A folder-writing adversary can
        // TAMPER an entry and recompute the whole chain from genesis, and nothing
        // is detected — exactly why only the keyed MAC gives real tamper evidence.
        let dir = tempfile::tempdir().unwrap();
        let log = EventLog::open(dir.path()).unwrap(); // no key → chain-only
        append_n(&log, 3);

        // Adversary: rewrite the segment with the MIDDLE entry's content changed,
        // then reseal the ENTIRE chain from genesis (keyless — no secret needed).
        let mut entries: Vec<LogEntry> = read_lines(&seg_path(dir.path()))
            .iter()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        if let Event::FileImported {
            ref mut original_name,
            ..
        } = entries[1].event
        {
            *original_name = "TAMPERED".into();
        }
        let mut prev = GENESIS_HASH.to_string();
        let mut lines = Vec::new();
        for e in entries.iter_mut() {
            e.seal(prev, None).unwrap(); // chain-only reseal, no MAC
            prev = e.chain_hash().unwrap();
            lines.push(serde_json::to_string(e).unwrap());
        }
        write_lines(&seg_path(dir.path()), &lines);

        // All three entries survive and the tampered content is served as trusted
        // — the recomputed chain evades every check. (A keyed log would quarantine
        // the tampered entry via its MAC; see `tampered_entry_is_quarantined_*`.)
        let events = log.read_all().unwrap();
        assert_eq!(events.len(), 3, "recomputed chain passes verification");
        let tampered_present = events.iter().any(|e| {
            matches!(&e.event, Event::FileImported { original_name, .. } if original_name == "TAMPERED")
        });
        assert!(
            tampered_present,
            "chain-only mode cannot detect the adversarial tamper"
        );
    }

    // ---- migration: seal legacy entries once, idempotently ------------------

    /// Write a legacy segment (entries with NO prev_hash/mac keys at all).
    fn write_legacy_segment(dir: &Path, n: i64) {
        let log_dir = dir.join("log");
        std::fs::create_dir_all(&log_dir).unwrap();
        let mut out = String::new();
        for seq in 1..=n {
            let ts = format!("2024-01-01T00:00:{:02}Z", seq);
            let e = mk_on("legacydev", seq, &ts);
            // Strip the optional keys to produce a genuine pre-change line.
            let mut v: serde_json::Value = serde_json::to_value(&e).unwrap();
            let obj = v.as_object_mut().unwrap();
            obj.remove("prev_hash");
            obj.remove("mac");
            out.push_str(&serde_json::to_string(&v).unwrap());
            out.push('\n');
        }
        std::fs::write(log_dir.join("legacydev-000001.jsonl"), out).unwrap();
    }

    /// One legacy log line (an entry with NO prev_hash/mac keys) as a string, so
    /// tests can assemble a segment line-by-line (e.g. inserting a torn or
    /// unparseable line at a chosen position).
    fn legacy_line(seq: i64, ts: &str) -> String {
        let e = mk_on("legacydev", seq, ts);
        let mut v: serde_json::Value = serde_json::to_value(&e).unwrap();
        let obj = v.as_object_mut().unwrap();
        obj.remove("prev_hash");
        obj.remove("mac");
        serde_json::to_string(&v).unwrap()
    }

    #[test]
    fn migrate_seals_legacy_log_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        write_legacy_segment(dir.path(), 3);
        let seg = dir.path().join("log/legacydev-000001.jsonl");

        let log = keyed_log(dir.path());
        // Before migration the raw lines carry no MAC.
        assert!(read_lines(&seg)
            .iter()
            .all(|l| !l.contains("\"mac\"") || l.contains("\"mac\":null")));

        log.migrate_and_seal().unwrap();

        // After migration every entry verifies clean under the key.
        let events = log.read_all().unwrap();
        assert_eq!(events.len(), 3, "all legacy entries sealed + verified");
        for e in &events {
            assert!(e.mac.is_some() && e.prev_hash.is_some());
            assert!(e.verify_mac(KEY).unwrap());
        }

        // Idempotent: re-running produces byte-identical output and no re-write
        // of an already-sealed segment.
        let bytes1 = std::fs::read(&seg).unwrap();
        log.migrate_and_seal().unwrap();
        let bytes2 = std::fs::read(&seg).unwrap();
        assert_eq!(bytes1, bytes2, "migration is idempotent (stable bytes)");
    }

    #[test]
    fn chain_only_migration_then_key_upgrade_adds_macs() {
        let dir = tempfile::tempdir().unwrap();
        write_legacy_segment(dir.path(), 2);
        let seg = dir.path().join("log/legacydev-000001.jsonl");

        // First migrate WITHOUT a key: adds the chain, no MAC.
        {
            let log = EventLog::open(dir.path()).unwrap();
            log.migrate_and_seal().unwrap();
        }
        assert!(read_lines(&seg).iter().all(|l| l.contains("prev_hash")));

        // Reopen WITH a key: migration now upgrades chain-only → MAC'd.
        let log = keyed_log(dir.path());
        log.migrate_and_seal().unwrap();
        let events = log.read_all().unwrap();
        assert_eq!(events.len(), 2);
        for e in &events {
            assert!(e.verify_mac(KEY).unwrap(), "MACs added on key upgrade");
        }
    }

    #[test]
    fn migration_aborts_on_unparseable_non_final_line_and_loses_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let log_dir = dir.path().join("log");
        std::fs::create_dir_all(&log_dir).unwrap();
        let seg = log_dir.join("legacydev-000001.jsonl");

        // A legacy segment whose MIDDLE line is an entry this build can't parse
        // (a forward-compat event type from a newer binary). It is NOT the final
        // line, so rewriting the segment during migration would permanently drop
        // it — migration must instead abort and leave the file untouched.
        let future = r#"{"event_id":"future","seq":2,"ts":"2024-01-01T00:00:02Z","device_id":"legacydev","type":"FutureEventFromNewerBuild","payload":123}"#;
        let lines = vec![
            legacy_line(1, "2024-01-01T00:00:01Z"),
            future.to_string(),
            legacy_line(3, "2024-01-01T00:00:03Z"),
        ];
        write_lines(&seg, &lines);
        let before = std::fs::read(&seg).unwrap();

        // Even though these legacy entries WOULD be sealed, the unparseable
        // non-final line makes migration a no-op for this segment.
        let log = keyed_log(dir.path());
        log.migrate_and_seal().unwrap();

        let after = std::fs::read(&seg).unwrap();
        assert_eq!(
            before, after,
            "segment with an unparseable non-final line is left byte-unchanged (nothing dropped)"
        );
    }

    #[test]
    fn migration_still_seals_segment_with_only_a_torn_final_line() {
        let dir = tempfile::tempdir().unwrap();
        let log_dir = dir.path().join("log");
        std::fs::create_dir_all(&log_dir).unwrap();
        let seg = log_dir.join("legacydev-000001.jsonl");

        // Two complete legacy entries followed by a torn/incomplete FINAL line
        // (a half-written append that never completed). The torn tail is
        // skippable, so migration still proceeds and seals the complete entries.
        let mut lines = vec![
            legacy_line(1, "2024-01-01T00:00:01Z"),
            legacy_line(2, "2024-01-01T00:00:02Z"),
        ];
        let torn = legacy_line(3, "2024-01-01T00:00:03Z");
        lines.push(torn[..torn.len() / 2].to_string());
        write_lines(&seg, &lines);

        let log = keyed_log(dir.path());
        log.migrate_and_seal().unwrap();

        // The two complete entries are sealed + verify; the torn final line is
        // dropped (it was never a completed append).
        let events = log.read_all().unwrap();
        let seqs: Vec<i64> = events.iter().map(|e| e.seq).collect();
        assert_eq!(
            seqs,
            vec![1, 2],
            "torn final line dropped, complete entries migrated"
        );
        for e in &events {
            assert!(
                e.verify_mac(KEY).unwrap(),
                "migrated entries are MAC-sealed"
            );
        }
    }
}
