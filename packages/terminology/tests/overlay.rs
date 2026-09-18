//! 运行时术语覆盖层:病种包给已有 key 加别名、定义新分析物(「加病不发版」的前提)。
//!
//! 这些测试**必须串行**跑:覆盖层是进程级全局状态。用一个互斥锁串起来,
//! 而不是 `--test-threads=1`(那要求每个跑测试的人都记得加参数)。
//!
//! 拿 `ch50`(总补体溶血活性)当例子,不是 UPCR —— UPCR 已经是内置条目了
//! (见 `dictionary.json` 的 `urine_pcr`),而 SLE 包真正缺的正是 CH50 /
//! 尿红白细胞(/HP)这几条(Task 11–15)。
use std::sync::Mutex;
use terminology::Entry;

static SERIAL: Mutex<()> = Mutex::new(());

/// 锁毒化(某条用例 panic 在锁里)不该把后面每条都变成二次失败 —— 这里的数据是
/// 一个普通 `Vec`,没有「改了一半」的中间态,恢复它是安全的。
fn serial() -> std::sync::MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|e| e.into_inner())
}

/// 病种包定义的新分析物。`U/L → U/mL` 的 0.001 是纯单位代数(1 U/L = 0.001 U/mL),
/// 不是任何临床换算 —— 用例只想证明「包带的换算表真的被用上了」。
fn ch50() -> Entry {
    serde_json::from_value(serde_json::json!({
        "key": "ch50", "canonical_name": "总补体溶血活性", "category": "lab",
        "system": "serum/plasma", "panel": "风湿免疫", "codes": {},
        "canonical_unit": "U/mL",
        "units": [{"unit": "U/mL", "slope": 1.0, "intercept": 0.0},
                  {"unit": "U/L", "slope": 0.001, "intercept": 0.0}],
        "aliases": ["总补体溶血活性", "CH50", "总补体活性"]
    }))
    .expect("夹具条目必须解析")
}

#[test]
fn an_overlay_analyte_resolves_and_carries_its_units() {
    let _g = serial();
    terminology::set_overlay(vec![]);
    assert!(
        terminology::resolve("总补体溶血活性", Some("U/mL")).is_none(),
        "内置词典里本来没有"
    );
    // 内置今天还会把 CH50 模糊猜成 CA50(肿瘤标志物,0.4)—— 包的精确别名必须压过
    // 这个猜测,否则「加病」加出来的是个更糟的错配。
    assert_ne!(
        terminology::resolve("CH50", Some("U/mL")).map(|m| m.key),
        Some("ch50".to_string())
    );

    terminology::set_overlay(vec![ch50()]);
    let m = terminology::resolve("总补体溶血活性", Some("U/mL")).expect("覆盖层要认出来");
    assert_eq!(m.key, "ch50");
    assert_eq!(m.confidence, 1.0, "精确别名命中 = 1.0,与内置同一条约定");
    let by_abbr = terminology::resolve("CH50", Some("U/mL")).expect("缩写也要认");
    assert_eq!(by_abbr.key, "ch50", "覆盖层的精确命中压过内置的模糊猜测");

    let e = terminology::entry_for("ch50").expect("entry_for 也要查覆盖层");
    assert_eq!(e.canonical_unit.as_deref(), Some("U/mL"));
    assert!(e
        .units
        .iter()
        .any(|u| u.unit == "U/L" && (u.slope - 0.001).abs() < 1e-12));
    terminology::set_overlay(vec![]);
}

#[test]
fn an_overlay_alias_on_an_existing_key_works_but_its_definition_is_ignored() {
    let _g = serial();
    terminology::set_overlay(vec![]);
    let mut c3 = terminology::entry_for("complement_c3").expect("内置有 C3");
    c3.aliases = vec!["血清补体C3测定".into()];
    // 同一条里顺手把单位改成 mg/L(与内置的 g/L 差 1000 倍)—— 别名要生效,
    // 这个定义必须一个字都不生效。
    c3.canonical_unit = Some("mg/L".into());
    c3.canonical_name = "假补体C3".into();
    terminology::set_overlay(vec![c3]);

    let m = terminology::resolve("血清补体C3测定", Some("g/L")).expect("包加的别名要认");
    assert_eq!(m.key, "complement_c3");
    assert_eq!(m.canonical_name, "补体C3", "名字来自内置,不是包");
    assert_eq!(
        terminology::entry_for("complement_c3")
            .expect("内置有 C3")
            .canonical_unit
            .as_deref(),
        Some("g/L"),
        "内置单位必须原封不动"
    );
    terminology::set_overlay(vec![]);
}

#[test]
fn an_overlay_alias_spelled_like_the_whole_printed_row_still_loses_to_the_builtin() {
    // 「内置优先」原本只在**同一个候选串**上成立:`resolve` 把所有候选的命中一起丢进
    // `pick_best` 竞争,而覆盖层命中和内置命中同为 1.0,排序键里谁的别名长谁赢。包只要
    // 把别名写成报告上**整行印的那个写法**(`term_candidates` 的头两个候选就是原串和
    // 去括号主体),就能把肌酐那一行连同它的 `units[]` 一起抢到自己 key 上 —— 等于绕开
    // 「改不掉定义」那条红线,换个 key 把肌酐的斜率改了。排序键第一位现在是「是不是
    // 内置」,任何置信度/长度都翻不过来。
    let _g = serial();
    let evil: Entry = serde_json::from_value(serde_json::json!({
        "key": "evil_creat2", "canonical_name": "假肌酐2", "category": "lab",
        "system": "serum/plasma", "codes": {"loinc": "00000-0"},
        "canonical_unit": "mg/dL",
        "units": [{"unit": "umol/L", "slope": 99.0, "intercept": 0.0}],
        "aliases": ["血清肌酐(Cr)", "肌酐 Cr"]
    }))
    .expect("夹具条目必须解析");
    let builtin_loinc = terminology::entry_for("creatinine")
        .expect("内置有肌酐")
        .codes
        .loinc;
    terminology::set_overlay(vec![evil]);
    for row in ["血清肌酐(Cr)", "肌酐 Cr"] {
        let m = terminology::resolve(row, Some("umol/L")).unwrap_or_else(|| panic!("{row}"));
        assert_eq!(m.key, "creatinine", "{row}");
        assert_eq!(m.canonical_name, "肌酐", "{row}");
        assert_eq!(
            m.codes.loinc, builtin_loinc,
            "{row}:LOINC 也必须是内置那条的"
        );
    }
    terminology::set_overlay(vec![]);
}

#[test]
fn an_overlay_can_never_shadow_a_builtin_definition() {
    // 被盗签的包不能把肌酐的单位改掉。内置命中就到此为止,覆盖层根本不查。
    let _g = serial();
    let mut evil: Entry = terminology::entry_for("creatinine").expect("内置有肌酐");
    evil.canonical_unit = Some("mg/dL".into());
    evil.canonical_name = "假肌酐".into();
    terminology::set_overlay(vec![evil]);
    let m = terminology::resolve("肌酐", Some("umol/L")).expect("内置认得肌酐");
    assert_eq!(m.key, "creatinine");
    assert_eq!(m.canonical_name, "肌酐", "内置定义必须原封不动");
    assert_eq!(
        terminology::entry_for("creatinine")
            .expect("内置有肌酐")
            .canonical_unit
            .as_deref(),
        Some("umol/L")
    );
    terminology::set_overlay(vec![]);
}

#[test]
fn clearing_the_overlay_really_clears_it() {
    let _g = serial();
    terminology::set_overlay(vec![ch50()]);
    assert!(terminology::entry_for("ch50").is_some());
    terminology::set_overlay(vec![]);
    assert!(terminology::entry_for("ch50").is_none());
    assert!(terminology::resolve("总补体溶血活性", Some("U/mL")).is_none());
}
