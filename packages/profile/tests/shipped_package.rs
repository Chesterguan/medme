//! 已发布的 SLE 包的硬约束。这些断言就是「包里不许编数字」的自动化形式。
//!
//! 与 `repo_packages_verify.rs` 分工:那边只问「签名验得过吗」,这边问「包里那些数
//! 站得住吗」—— 每个数有没有出处、每个阈值有没有单位、没核实的有没有如实写 null。
//!
//! ⚠️ 独占一个测试二进制里的**一条**用例会动 `terminology::set_overlay`(进程级全局
//! 状态)。所有要覆盖层的断言都塞在 `the_shipped_package_reads_the_synthetic_corpus`
//! 那一条里,不拆开 —— 拆开就得上串行锁(见 `golden_sle_course.rs` 的同一条注释)。
use std::path::{Path, PathBuf};

mod common;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..")
}

/// 作者手写的那一份(`.src.json`)。断言大多打在它身上:信封里装的就是这串字节,
/// 而对着源文件断言时,失败信息指得回作者要改的那一行。
fn src_json() -> serde_json::Value {
    serde_json::from_str(common::FULL).expect("发布包必须是合法 JSON")
}

/// 签好的信封走**生产路径**加载:用编进二进制的生产公钥验签 + 过引擎版本闸。
fn signed_pkg() -> profile::Package {
    let signed = std::fs::read_to_string(repo().join("skills/sle/2026.09.1.json"))
        .expect("签好的包必须在仓库里");
    profile::load_signed(&signed).expect("已发布的 SLE 包必须用生产公钥验过并加载")
}

fn source_ids(pkg: &profile::Package) -> Vec<String> {
    pkg.manifest.sources.iter().map(|s| s.id.clone()).collect()
}

// --- 信封 = 源文件 ---------------------------------------------------------

#[test]
fn the_signed_envelope_carries_exactly_the_source_file() {
    // 夹具包(`common::FULL`)与签出去的那份必须是同一份内容 —— 否则 golden
    // ProfileView 钉住的是一个用户永远装不上的包。
    let signed = signed_pkg();
    let a = src_json();
    let b = serde_json::to_value(serde_json::json!({
        "id": signed.manifest.id, "version": signed.manifest.version,
        "min_engine": signed.manifest.min_engine,
    }))
    .expect("json");
    assert_eq!(b["id"], "sle");
    assert_eq!(b["version"], a["manifest"]["version"]);
    assert_eq!(b["min_engine"], 1, "min_engine 必须是 1");
    // 逐字节:信封内层原文就是 `.src.json` 的全文。
    let raw = std::fs::read_to_string(repo().join("skills/sle/2026.09.1.json")).expect("信封");
    let body = profile::verify_envelope_body(&raw).expect("验签");
    assert_eq!(body, common::FULL, "信封里装的不是 .src.json 那串字节");
}

// --- 出处 ------------------------------------------------------------------

/// `rules` 底下**每一个带标量的对象**都要有 source —— 不只是带 value/threshold/
/// every_days 的那些。activity 的条目带 `weight`,states 的条目带 `kind`,
/// monitoring 的 `phases[]` 只带天数,bands 的每一行只带 `label`:谓词漏掉任何
/// 一类,就等于「只有一半的数字被出处覆盖」。
///
/// 判定只有一条:**对象里出现任何标量值(非对象、非数组)就必须有 source**。
/// 纯容器(所有值都是对象/数组,如 `rules.targets`)豁免。
#[test]
fn every_rule_object_declares_a_source_that_exists() {
    let ids = source_ids(&signed_pkg());
    let mut checked = 0usize;
    fn walk(v: &serde_json::Value, ids: &[String], path: &str, checked: &mut usize) {
        match v {
            serde_json::Value::Object(m) => {
                let has_scalar = m
                    .iter()
                    .any(|(k, x)| k != "source" && !x.is_object() && !x.is_array());
                if has_scalar {
                    let s = m.get("source").and_then(|x| x.as_str()).unwrap_or_else(|| {
                        panic!("{path} 带着数值/文案却没有 source");
                    });
                    assert!(
                        ids.iter().any(|i| i == s),
                        "{path} 的 source {s} 没在 manifest.sources 里"
                    );
                    *checked += 1;
                }
                for (k, x) in m {
                    walk(x, ids, &format!("{path}.{k}"), checked);
                }
            }
            serde_json::Value::Array(a) => {
                for (i, x) in a.iter().enumerate() {
                    walk(x, ids, &format!("{path}[{i}]"), checked);
                }
            }
            _ => {}
        }
    }
    let v = src_json();
    walk(&v["rules"], &ids, "pkg.rules", &mut checked);
    // 防「谓词写歪了导致一个都没查」。
    assert!(
        checked >= 40,
        "只核到 {checked} 个规则对象,谓词可能又漏了一整类"
    );
    for group in [
        "activity",
        "states",
        "monitoring",
        "milestones",
        "targets",
        "bands",
    ] {
        assert!(!v["rules"][group].is_null(), "rules.{group} 不该缺席");
    }
}

#[test]
fn every_source_id_a_note_names_is_declared_too() {
    // 上一条只看对象有没有 `source` 键,看不见 **note 里点名的别人**。而 `note` 会
    // 原样进 ProfileView(`eval_milestone`/`eval_monitor` 把包里那条规则整条带出),
    // 所以 note 里印的每一个出处 id 都得能在界面的「id → 全文」表里查到 ——
    // 查不到的那个 id,用户点开是空的。
    let ids = source_ids(&signed_pkg());
    let mut seen = 0usize;
    fn walk(v: &serde_json::Value, ids: &[String], path: &str, seen: &mut usize) {
        match v {
            serde_json::Value::Object(m) => {
                for (k, x) in m {
                    let p = format!("{path}.{k}");
                    if let Some(s) = x.as_str() {
                        // 形如 S8 / L1 / R1 的 token。`§E.2`、`SLEDAI-2K`、`H02AB`
                        // 都配不上(要求首字母是 S/L/R 且**紧跟**数字、两侧断词)。
                        for tok in s.split(|c: char| !c.is_ascii_alphanumeric()) {
                            let looks_like_id =
                                matches!(tok.as_bytes().first(), Some(b'S' | b'L' | b'R'))
                                    && tok.len() > 1
                                    && tok[1..].bytes().all(|b| b.is_ascii_digit());
                            if !looks_like_id {
                                continue;
                            }
                            assert!(
                                ids.iter().any(|i| i == tok),
                                "{p} 的文案里点名了出处 {tok},但 manifest.sources 没有它"
                            );
                            *seen += 1;
                        }
                    }
                    walk(x, ids, &p, seen);
                }
            }
            serde_json::Value::Array(a) => {
                for (i, x) in a.iter().enumerate() {
                    walk(x, ids, &format!("{path}[{i}]"), seen);
                }
            }
            _ => {}
        }
    }
    let v = src_json();
    for top in ["rules", "terms", "drugs", "markers", "views"] {
        walk(&v[top], &ids, &format!("pkg.{top}"), &mut seen);
    }
    assert!(
        seen >= 10,
        "只扫到 {seen} 个 note 里的出处 id,谓词可能没生效"
    );
}

#[test]
fn every_terms_analyte_and_drug_row_says_where_its_numbers_came_from() {
    // `terms`/`drugs` 不在 `rules` 下,但同样是「会印到用户眼前的事实」:
    // 新分析物的单位换算系数、生物制剂的输注周期都必须能追到出处或写明待核。
    let v = src_json();
    for a in v["terms"]["analytes"].as_array().expect("analytes 是数组") {
        let note = a["note"].as_str().unwrap_or_default();
        assert!(
            !note.is_empty(),
            "{} 没有 note(换算与编码的来源/待核状态)",
            a["key"]
        );
    }
    let ids = source_ids(&signed_pkg());
    for d in v["drugs"].as_array().expect("drugs 是数组") {
        if d["infusion"].is_null() {
            continue;
        }
        let src = d["infusion_source"].as_str().unwrap_or_default();
        assert!(!src.is_empty(), "{} 给了输注周期就必须给出处", d["class"]);
        assert!(
            ids.iter().any(|i| i == src),
            "{} 的 infusion_source {src} 没在 manifest.sources 里",
            d["class"]
        );
    }
}

// --- 阈值单位 --------------------------------------------------------------

#[test]
fn every_numeric_threshold_carries_the_unit_it_is_written_in() {
    // `threshold` 配 `threshold_unit` 是成对的:少了单位,引擎读不到就整条落未知
    // (`rules.rs::NO_THRESHOLD_UNIT`)—— 方向安全,但那一条从此永远算不出来。
    let v = src_json();
    fn walk(v: &serde_json::Value, path: &str, seen: &mut usize) {
        match v {
            serde_json::Value::Object(m) => {
                if m.contains_key("threshold") && !m["threshold"].is_null() {
                    assert!(
                        m.get("threshold_unit").and_then(|x| x.as_str()).is_some(),
                        "{path} 写了 threshold 却没写 threshold_unit"
                    );
                    *seen += 1;
                }
                for (k, x) in m {
                    walk(x, &format!("{path}.{k}"), seen);
                }
            }
            serde_json::Value::Array(a) => {
                for (i, x) in a.iter().enumerate() {
                    walk(x, &format!("{path}[{i}]"), seen);
                }
            }
            _ => {}
        }
    }
    let mut seen = 0;
    walk(&v["rules"], "pkg.rules", &mut seen);
    assert!(seen >= 6, "只看到 {seen} 个阈值,谓词可能漏了");
}

#[test]
fn the_old_canonical_unit_field_name_appears_nowhere() {
    // 旧名在骗包作者:它是**阈值自己写的单位**,不是规范单位。改名时刻意不留 serde
    // 兼容(`rules.rs::threshold_unit`),所以包里残留一个旧名 = 那条规则静默失效。
    fn walk(v: &serde_json::Value, path: &str) {
        match v {
            serde_json::Value::Object(m) => {
                assert!(
                    !m.contains_key("canonical_unit"),
                    "{path} 还在用旧字段名 canonical_unit"
                );
                for (k, x) in m {
                    walk(x, &format!("{path}.{k}"));
                }
            }
            serde_json::Value::Array(a) => {
                for (i, x) in a.iter().enumerate() {
                    walk(x, &format!("{path}[{i}]"));
                }
            }
            _ => {}
        }
    }
    // `terms.analytes[].canonical_unit` 是**词典条目**的字段,与规则里那个同名不同
    // 义,所以只扫 `rules`。
    walk(&src_json()["rules"], "pkg.rules");
}

// --- 监测规则 --------------------------------------------------------------

#[test]
fn every_monitoring_row_declares_a_verify_status() {
    // fail closed:`monitor_pending` 只认逐字 `"verified"`,漏写一律算待核。漏写
    // 不会出错,但会让一条本该到期的提醒永远不到期 —— 那是静默的,所以在这里挡。
    let v = src_json();
    let rows = v["rules"]["monitoring"]
        .as_array()
        .expect("monitoring 是数组");
    assert!(rows.len() >= 15, "只有 {} 条监测规则", rows.len());
    for m in rows {
        let id = m["id"].as_str().unwrap_or_default();
        assert!(!id.is_empty(), "有条监测规则没有 id:{m}");
        let st = m["verify_status"].as_str().unwrap_or_default();
        assert!(
            ["verified", "pending"].contains(&st),
            "{id} 的 verify_status 是 {st:?}"
        );
        let basis = m["basis"].as_str().unwrap_or_default();
        assert!(
            ["guideline", "label", "literature", "package_default"].contains(&basis),
            "{id} 的 basis 是 {basis:?}"
        );
        // 逐字的数才配 verified:凡是 basis=package_default 的,一律不许 verified。
        if basis == "package_default" {
            assert_eq!(st, "pending", "{id}:包默认值不许标成已核实");
        }
    }
}

#[test]
fn package_default_monitoring_rules_are_labelled_as_such() {
    let v = src_json();
    for id in ["mtx_labs", "ctx_cbc"] {
        let m = v["rules"]["monitoring"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["id"] == id)
            .unwrap_or_else(|| panic!("{id} 不见了"));
        assert_eq!(
            m["basis"], "package_default",
            "{id} 的说明书只写「定期」,不许冒充指南"
        );
        assert_eq!(m["source"], "PKG");
    }
}

#[test]
fn the_extrapolated_mmf_phase_is_its_own_package_default() {
    // 说明书逐字只写到「the remainder of the first year」。第一年之后那一档是外推,
    // 必须以自己的身份出去,不能顶着「出处=说明书」的标签被算成到期日。
    let v = src_json();
    let mmf = v["rules"]["monitoring"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == "mmf_cbc")
        .expect("mmf_cbc");
    let phases = mmf["phases"].as_array().expect("phases");
    let last = phases.last().expect("至少一档");
    assert!(last["until_days"].is_null(), "最后一档不该有终点");
    assert_eq!(last["basis"], "package_default");
    assert_eq!(last["verify_status"], "pending");
    assert!(last["note"].as_str().unwrap_or_default().contains("外推"));
    // 前三档是逐字的,不许自带 pending 把它们也压住。
    for p in &phases[..phases.len() - 1] {
        assert!(
            p["verify_status"].is_null(),
            "逐字那几档不该写 verify_status:{p}"
        );
    }
}

// --- 没核实的一律 null + 待核 ----------------------------------------------

#[test]
fn unverified_values_are_null_with_a_todo_note_not_invented_numbers() {
    let v = src_json();
    let gc = v["drugs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["class"] == "gc")
        .expect("gc");
    // Task 19 从 S10 一手全文(PMC9524765, Table 3)取到了等效剂量表,所以这条从
    // 「必须是 null」翻成「已填,且每个系数都指得回那张表」。
    let ids = source_ids(&signed_pkg());
    let tbl = gc["pred_equiv"]
        .as_object()
        .expect("等效换算表已核实,应已填上");
    let src = gc["pred_equiv_source"]
        .as_str()
        .expect("填了表就必须给出处");
    assert!(
        ids.iter().any(|i| i == src),
        "pred_equiv_source {src} 没在 manifest.sources 里"
    );
    // S10 Table 3 的等效剂量(mg);包里存的系数 = 5 ÷ 等效剂量。逐条对着原表核。
    for (name, equiv_mg) in [
        ("氢化可的松", 20.0),
        ("可的松", 25.0),
        ("泼尼松", 5.0),
        ("泼尼松龙", 5.0),
        ("甲泼尼龙", 4.0),
        ("曲安西龙", 4.0),
        ("倍他米松", 0.60),
        ("地塞米松", 0.75),
    ] {
        let f = tbl[name]
            .as_f64()
            .unwrap_or_else(|| panic!("{name} 没有系数"));
        assert!(
            (equiv_mg * f - 5.0).abs() < 1e-9,
            "{name}:{equiv_mg} mg × {f} 应等于 5 mg 泼尼松"
        );
    }
    // 「可的松」是「氢化可的松」的子串,而引擎按最长键匹配 —— 漏掉氢化可的松那一行,
    // 氢化可的松就会套用可的松的 0.2,算低 20%。
    assert!(
        tbl.contains_key("氢化可的松"),
        "氢化可的松必须单列,否则被可的松吃掉"
    );
    // 包自带的两个分析物,LOINC 由 NLM 的 LOINC 服务逐条查得(S17)。
    for (key, loinc) in [("urine_rbc_hpf", "13945-1"), ("urine_wbc_hpf", "5821-4")] {
        let a = v["terms"]["analytes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["key"] == key)
            .unwrap_or_else(|| panic!("{key}"));
        assert_eq!(a["loinc"], loinc, "{key} 的 LOINC");
        assert!(
            a["note"].as_str().unwrap_or_default().contains("S17"),
            "{key} 要点名出处"
        );
    }
}

#[test]
fn the_dxa_age_threshold_is_null_because_the_guideline_gates_only_frax_on_age() {
    // Task 19 拿到 ACR 2022 GIOP 已刊全文(eScholarship)后翻案:「≥40 岁」是挂在
    // **FRAX** 上的,不是挂在骨密度上 —— 原文另有「BMD with VFA testing or spinal
    // x-ray is advised in patients <40 years, as FRAX is not validated in this
    // population」。所以 min_age 仍是 null,但理由从「没核到」变成「核到了,指南
    // 本来就不按年龄卡骨密度」;拿 40 岁当门槛会把 SLE 的主力发病年龄挡在外面。
    let v = src_json();
    let r = v["rules"]["monitoring"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == "gc_dxa")
        .expect("gc_dxa");
    assert_eq!(r["min_daily_pred_equiv"], 2.5);
    // 原文是 more than 3 months(超过、不含),而 `min_days` 在引擎里是「至少这么多
    // 天」(含),所以下限是 91 不是 90(Task 14 的 m1,与 gc_ca_vitd 同一条)。
    assert_eq!(r["min_days"], 91);
    assert!(
        r["min_age"].is_null(),
        "骨密度不按年龄卡,min_age 必须是 null"
    );
    assert_eq!(r["verify_status"], "verified");
    // 年龄的真实作用(要不要加做 FRAX)得让用户看得见,否则这条就在悄悄少说一半。
    let action = r["action"].as_str().unwrap_or_default();
    assert!(action.contains("FRAX") && action.contains("40"), "{action}");
}

#[test]
fn the_package_never_uses_the_unsourced_five_band_sledai_scheme() {
    // sle-clinical-sources §G.1:那套五档分级追不到一手出处,不许发。
    for banned in ["11-19", "11–19", "≥20"] {
        assert!(
            !common::FULL.contains(banned),
            "出现了未经核实的五档分级:{banned}"
        );
    }
    let bands = src_json()["rules"]["bands"]["bands"]
        .as_array()
        .expect("bands 是数组")
        .len();
    assert_eq!(bands, 3, "只用 ≤6 / 7–12 / >12 三档(两份指南一致)");
}

// --- 羟氯喹:指南那组数留下,核不到的说明书整块撤掉 ------------------------

#[test]
fn the_hcq_rule_keeps_the_guideline_numbers_and_ships_no_unverified_insert() {
    let v = src_json();
    let h = &v["rules"]["targets"]["hcq"];
    // 指南那组数 Task 19 在 S4 原文 + S9 原文上都逐字核过了,留着。
    assert_eq!(h["target"], 5);
    assert_eq!(h["basis"], "real_body_weight");
    assert_eq!(h["ceiling_mg"], 400);
    // `target_source` 是引擎在现行方案卡上读的那个键(`rules.rs::hcq_body`)。
    assert_eq!(h["target_source"], "S4");
    // 两份中文说明书只经过摘要管道,而那条管道编造过两次羟氯喹剂量;Task 19 试了
    // NMPA 数据库与生产企业站点都没拿到一手件,所以整块撤掉 —— 宁可不说,不能说
    // 一句没核过的。撤掉的理由留在 `label_rule_note` 里,免得下一个人又把它抄回来。
    assert!(h["label_rule"].is_null(), "没核到的说明书不许发");
    assert!(
        h["label_rule_note"]
            .as_str()
            .unwrap_or_default()
            .contains("NMPA"),
        "要写清楚试过哪些一手来源、怎么失败的"
    );
    // 那两个数彻底不在包里,任何地方都不能再出现。
    // **先去掉所有空白再比**:写成「6.5 mg/kg」(带空格)就绕过字面量比对了
    // —— fix round 1 的 M3。
    let squashed: String = common::FULL
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    assert!(
        !squashed.contains("6.5mg/kg"),
        "说明书的 6.5 mg/kg 应已撤掉"
    );
    assert!(
        !squashed.contains("6.5毫克/公斤"),
        "同一个数的中文写法也不许"
    );
    assert!(!squashed.contains("理想体重"), "理想体重那套算法应已撤掉");
}

/// 这几个键装的是**给人读的文案**;判定读的是别的键。
const PROSE_KEYS: [&str; 8] = [
    "note",
    "text",
    "label",
    "caveat",
    "action",
    "cite",
    "target",
    "corroborated_by",
];

#[test]
fn the_package_insert_numbers_never_drive_a_judgement() {
    // Task 19 之前这条只能要求「6.5 / 理想体重只许待在文案里」,因为 `label_rule`
    // 整块就是把说明书原话摆出来。现在那一块已经撤掉(核不到一手件),所以这条
    // 收紧成**全包禁字**:6.5 不许当任何非文案标量,「理想体重」「每3月」不许出现
    // 在任何字符串里 —— 连 note 也不行,note 是会原样印到用户眼前的。
    fn walk(v: &serde_json::Value, path: &str) {
        match v {
            serde_json::Value::Object(m) => {
                for (k, x) in m {
                    let p = format!("{path}.{k}");
                    if let Some(s) = x.as_str() {
                        for banned in ["理想体重", "每3月", "每 3 月"] {
                            assert!(!s.contains(banned), "{p} 里出现了说明书数值:{banned}");
                        }
                    }
                    if PROSE_KEYS.contains(&k.as_str()) && !x.is_object() && !x.is_array() {
                        continue;
                    }
                    if let Some(n) = x.as_f64() {
                        assert!((n - 6.5).abs() > f64::EPSILON, "{p} 是说明书那个 6.5");
                    }
                    walk(x, &p);
                }
            }
            serde_json::Value::Array(a) => {
                for (i, x) in a.iter().enumerate() {
                    walk(x, &format!("{path}[{i}]"));
                }
            }
            _ => {}
        }
    }
    // **整包**,不只 `rules` —— `drugs`/`terms`/`manifest` 里同样不许出现那几个字。
    // (上一轮注释写着「全包」,代码却只走了 `rules`;fix round 1 的 M2。)
    walk(&src_json(), "pkg");

    // 眼科那条同理:三份来源互相矛盾、危险因素档案里也没有,所以它**根本不给间隔**。
    let eye = src_json()["rules"]["monitoring"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == "hcq_eye")
        .expect("hcq_eye")
        .clone();
    assert_eq!(
        eye["phases"].as_array().map(Vec::len),
        Some(0),
        "不许有间隔"
    );
    assert_eq!(eye["verify_status"], "pending");
}

// --- 视图 ------------------------------------------------------------------

#[test]
fn views_cover_every_section_kind_the_engine_can_emit() {
    // 标题全来自包(spec §6:引擎里没有一句写死的病种文案),所以包里漏一种 kind,
    // 界面上那一块就是没名字的。
    //
    // ⚠️ `id` 不能见谁都加:`rules.rs::view_section` 用 `id == None` 去配**压根没写
    // id 那个键**的条目,只有里程碑那块(与达标表同为 checklist)靠 id 区分。给别的
    // 块加 id,它们的标题查找会全部落空。
    let v = src_json();
    let sections = v["views"]["sections"].as_array().expect("sections 是数组");
    let want: [(&str, Option<&str>); 7] = [
        ("status_card", None),
        ("score_card", None),
        ("reminders", None),
        ("series_chart", None),
        ("timeline", None),
        ("checklist", None),
        ("checklist", Some("ln_milestones")),
    ];
    for (kind, id) in want {
        let hit = sections
            .iter()
            .find(|s| s["kind"] == kind && s.get("id").and_then(|x| x.as_str()) == id)
            .unwrap_or_else(|| panic!("views.sections 里没有 {kind} / id={id:?}"));
        assert!(
            hit["title"].as_str().is_some_and(|t| !t.is_empty()),
            "{kind} / id={id:?} 没有标题"
        );
    }
    let timeline = sections.iter().find(|s| s["kind"] == "timeline").unwrap();
    let high = timeline["severity_high"]
        .as_array()
        .expect("severity_high 是数组");
    assert!(
        high.iter().any(|x| x == "flare"),
        "复发标红是包说的,不是引擎自己判的"
    );
    assert!(!v["views"]["handoff"]
        .as_array()
        .expect("handoff 是数组")
        .is_empty());
}

#[test]
fn the_disclaimer_and_engine_gate_are_what_the_spec_says() {
    let p = signed_pkg();
    assert_eq!(p.manifest.disclaimer, "仅整理你的病历,不做诊断");
    assert_eq!(p.manifest.min_engine, 1);
    assert_eq!(p.manifest.family, "immune");
    assert_eq!(p.manifest.display.name, "系统性红斑狼疮");
}

// --- 真语料跑一遍 ----------------------------------------------------------

/// 覆盖层是进程级全局状态,所以要它的断言全挤在这一条里(见文件头)。
#[test]
fn the_shipped_package_reads_the_synthetic_corpus() {
    let pkg = signed_pkg();
    terminology::set_overlay(common::overlay_entries(&pkg));

    // 1. 包自带的每个别名都真能解析回它自己的 key。内置词典优先,所以随手写一个
    //    「尿红细胞」只会解析成内置的 urine_rbc_count —— 那一项会静默变成另一个概念。
    let mut alias_fail = Vec::new();
    for a in &pkg.terms.analytes {
        for alias in &a.aliases {
            match terminology::resolve(alias, None) {
                Some(m) if m.key == a.key => {}
                other => alias_fail.push(format!(
                    "{alias} → {:?}(想要 {})",
                    other.map(|m| m.key),
                    a.key
                )),
            }
        }
    }

    // 2. 拿真语料跑一次 materialize,看哪些条目落进「未知」。
    let corpus = load_corpus();
    let docs: Vec<parser::SourceDoc> = corpus
        .iter()
        .enumerate()
        .map(|(i, (kind, date, text))| parser::SourceDoc {
            index: i,
            date: Some(*date),
            text,
            doc_type: Some(doc_type_for(kind)),
            title: None,
            extraction_json: None,
        })
        .collect();
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: common::PKG_ID.into(),
        at: "2024-03-15".into(),
        payload: serde_json::json!({}),
    }];
    let view = profile::materialize(&docs, &events, &pkg, "2026-09-16".parse().unwrap());
    terminology::set_overlay(vec![]);

    assert!(
        alias_fail.is_empty(),
        "包里的别名解析不回自己的 key:{alias_fail:?}"
    );

    // 每一块都得有标题 —— 没标题就是包里漏了这一种 kind 的配置。
    for s in &view.sections {
        assert!(
            s.title.is_some(),
            "{} / id={:?} 这一块在包里没有标题",
            s.kind,
            s.id
        );
    }

    // 活动度那张卡:语料最后一张单子是 2026-09-10 的补体/dsDNA/血常规,10 天窗口内。
    // 「这一项没做」是正常的未知;「认不出这个名字」不是 —— 后者说明别名漏了。
    let card = view
        .sections
        .iter()
        .find(|s| s.kind == "score_card")
        .expect("有活动度卡");
    let reasons: Vec<String> = card.body["unscored"]
        .as_array()
        .expect("unscored 是数组")
        .iter()
        .map(|u| format!("{}: {}", u["id"], u["reason"]))
        .collect();
    for r in &reasons {
        assert!(
            !r.contains("单位换算不成") && !r.contains("规则本机还算不了"),
            "未知的理由不该是「认不出/换不了」:{r}(全部:{reasons:?})"
        );
    }
    assert!(
        card.body["score"].as_u64().is_some_and(|s| s > 0),
        "真语料在窗口内该算得出分:{}",
        card.body
    );
}

// --- 语料装载(与 golden_sle_course.rs 同一套,两个二进制各编一份) -----------

fn load_corpus() -> Vec<(String, chrono::NaiveDate, String)> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("testdata")
        .join("corpus");
    let mut out = Vec::new();
    for f in std::fs::read_dir(dir).expect("语料目录").flatten() {
        let p = f.path();
        let stem = p
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        let mut parts = stem.splitn(3, '_');
        let Some(date) = parts.next().and_then(|d| d.parse().ok()) else {
            continue;
        };
        let kind = parts.next().unwrap_or_default().to_string();
        out.push((kind, date, std::fs::read_to_string(&p).expect("语料文件")));
    }
    out.sort_by_key(|(_, d, _)| *d);
    out
}

fn doc_type_for(kind: &str) -> String {
    match kind {
        "检验报告" => "lab_report",
        "处方" => "prescription",
        "出院记录" => "discharge_summary",
        "门诊病历" => "outpatient",
        "病理报告" => "pathology",
        "眼科报告" | "输液记录" => "clinical_note",
        _ => "other",
    }
    .to_string()
}
