//! 每对 fixture:脱敏后逐字节等于 .expected.txt(偏移 0 天),且已知身份在输出里不出现。
//! `tests/fixtures/known-gaps/` 单独一个测试跑:只报告当前是否还漏,不让 CI 失败
//! ——那些是审阅中记录、还没修的已知盲区,executable 的差距清单。
use deid::{assert_clean, redact_text, KnownIdentity};
use std::fs;
use std::path::Path;

fn parse_known(first_line: &str) -> KnownIdentity {
    let body = first_line.trim_start_matches("# known:").trim();
    let mut it = body.split('|').map(str::trim);
    let name = it.next().unwrap_or("").to_string();
    let opt = |s: Option<&str>| s.filter(|v| *v != "-" && !v.is_empty()).map(str::to_string);
    KnownIdentity { name, id_number: opt(it.next()), phone: opt(it.next()) }
}

#[test]
fn every_fixture_pair_redacts_to_expected() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let mut n = 0;
    for entry in fs::read_dir(&dir).expect("fixtures dir") {
        let p = entry.expect("entry").path();
        let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !name.ends_with(".txt") || name.ends_with(".expected.txt") {
            continue;
        }
        let src = fs::read_to_string(&p).expect("read fixture");
        let (first, rest) = src.split_once('\n').expect("first line is # known:");
        let known = parse_known(first);
        let expected = fs::read_to_string(p.with_extension("expected.txt")).expect("expected file");
        let r = redact_text(rest, &known, 0);
        assert_eq!(r.text, expected, "fixture {name}");
        assert_clean(&r.text, &known).unwrap_or_else(|e| panic!("{name}: {e}"));
        n += 1;
    }
    assert!(n >= 6, "至少 6 对 fixture,现在 {n}");
}

/// 已知盲区(Task 2 审阅记录,尚未修):只跑、只报告,不断言、不让测试失败。
/// 每对同样是 `<n>.txt` + `.expected.txt`,`.expected.txt` 记录的是**当前**(有漏洞的)
/// 实际输出,跑一遍打印出"仍然漏/已修好",方便下次改完 patterns.rs 时一眼看出差距缩小了。
#[test]
fn known_gaps_are_reported_not_enforced() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/known-gaps");
    let mut n = 0;
    for entry in fs::read_dir(&dir).expect("known-gaps dir") {
        let p = entry.expect("entry").path();
        let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !name.ends_with(".txt") || name.ends_with(".expected.txt") {
            continue;
        }
        let src = fs::read_to_string(&p).expect("read fixture");
        let (first, rest) = src.split_once('\n').expect("first line is # known:");
        let known = parse_known(first);
        let expected = fs::read_to_string(p.with_extension("expected.txt")).expect("expected file");
        let r = redact_text(rest, &known, 0);
        let still_gap = r.text != expected;
        println!(
            "[known-gap {}] {} | in: {:?} out: {:?}",
            name,
            if still_gap { "已改变(去核实是修好了还是换了种漏法)" } else { "仍是记录的老样子,盲区还在" },
            rest,
            r.text
        );
        n += 1;
    }
    assert!(n >= 1, "known-gaps 目录应至少有 1 对");
}
