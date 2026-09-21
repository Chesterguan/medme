//! 每对 fixture:脱敏后逐字节等于 .expected.txt(偏移 0 天),且已知身份在输出里不出现。
//! `tests/fixtures/known-gaps/` 单独一个测试跑:钉住**当前**(有漏洞的)输出,只在
//! 这个输出发生变化时才失败——那些是审阅中记录、还没修的已知盲区,executable 的
//! 差距清单;失败说明盲区的表现变了(修好了该升级成主 fixture,没修好该确认是不是
//! 换了种漏法),而不是意味着测试本身在断言"必须一直漏"。
use deid::{assert_clean, redact_text, KnownIdentity};
use std::fs;
use std::path::Path;

fn parse_known(first_line: &str) -> KnownIdentity {
    let body = first_line.trim_start_matches("# known:").trim();
    let mut it = body.split('|').map(str::trim);
    let name = it.next().unwrap_or("").to_string();
    let opt = |s: Option<&str>| s.filter(|v| *v != "-" && !v.is_empty()).map(str::to_string);
    KnownIdentity {
        name,
        id_number: opt(it.next()),
        phone: opt(it.next()),
    }
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

/// 已知盲区(Task 2 审阅记录,尚未修):钉住当前(有漏洞的)输出,只有这个输出变了
/// 才失败——`.expected.txt` 存的是**现状**,不是"期望修好后的样子",所以平时是绿的;
/// 一旦变红,去核实是修好了(该把这对 fixture 升级成主 fixture)还是只是换了种漏法。
#[test]
fn known_gaps_are_pinned_not_enforced() {
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
        let changed = r.text != expected;
        println!(
            "[known-gap {name}] {} | in: {rest:?} out: {:?}",
            if changed {
                "已改变(核实是修好了还是换了种漏法)"
            } else {
                "仍是记录的老样子,盲区还在"
            },
            r.text
        );
        assert_eq!(
            r.text, expected,
            "{name}: 盲区输出变了 — 核实是修好了(提升为主 fixture)还是换了种漏法"
        );
        n += 1;
    }
    assert!(n >= 1, "known-gaps 目录应至少有 1 对");
}
