//! 通用病程档案层(2026-10-22 spec)的 golden 与断言:合成病人 Doe, Jane
//! (瓣膜置换 + 曲霉菌),语料由 `examples/demo-dataset/generate_jane.sh` 直接写进
//! `testdata/corpus-jane/`(文本 + Epic 适配器样式 sidecar)。**不要手改夹具**。
//!
//! 独占一个测试二进制:包叠加用例要 `terminology::set_overlay`(进程级全局)。
use chrono::NaiveDate;
use std::path::{Path, PathBuf};

mod common;

fn corpus_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata/corpus-jane")
}

pub struct Doc {
    pub stem: String,
    pub kind: String,
    pub date: NaiveDate,
    pub text: String,
    pub sidecar: String,
}

/// 文件名形如 `2025-06-14_出院记录_UF.txt`;同 stem 的 `.json` 是 sidecar。按日期升序,
/// 同日按文件名。
pub fn load_corpus() -> Vec<Doc> {
    let mut out = Vec::new();
    for f in std::fs::read_dir(corpus_dir()).unwrap().flatten() {
        let p = f.path();
        if p.extension().is_none_or(|e| e != "txt") {
            continue;
        }
        let stem = p.file_stem().unwrap().to_string_lossy().to_string();
        let mut parts = stem.splitn(3, '_');
        let date: NaiveDate = parts.next().unwrap().parse().unwrap();
        let kind = parts.next().unwrap().to_string();
        let sidecar = std::fs::read_to_string(p.with_extension("json"))
            .unwrap_or_else(|e| panic!("{stem}.json 缺:{e}"));
        out.push(Doc {
            stem: stem.clone(),
            kind,
            date,
            text: std::fs::read_to_string(&p).unwrap(),
            sidecar,
        });
    }
    out.sort_by(|a, b| a.date.cmp(&b.date).then(a.stem.cmp(&b.stem)));
    out
}

pub fn doc_type_for(kind: &str) -> &'static str {
    match kind {
        "检验报告" => "lab_report",
        "出院记录" => "discharge_summary",
        "门诊病历" | "急诊记录" => "clinical_note",
        "手术记录" => "surgery",
        "影像报告" => "imaging_report",
        "病理报告" => "pathology",
        _ => "other",
    }
}

#[test]
fn corpus_is_complete_and_sidecars_are_verbatim_subsets_of_their_text() {
    let corpus = load_corpus();
    assert!(corpus.len() >= 15, "实际 {}", corpus.len());
    for d in &corpus {
        let parsed = deid::parse_extraction(&d.sidecar).expect("sidecar 是合法 JSON");
        let n = parsed.labs.len() + parsed.meds.len() + parsed.diagnoses.len();
        let v = deid::verify(parsed, &d.text, deid::Mode::Text);
        assert_eq!(
            v.rejected, 0,
            "{}:sidecar 里有 {} 条在文本里找不到(共 {n} 条)",
            d.stem, v.rejected
        );
    }
    let stems: Vec<&str> = corpus.iter().map(|d| d.stem.as_str()).collect();
    assert!(stems.contains(&"2025-11-17_门诊病历_UF"));
    assert_eq!(corpus.iter().filter(|d| d.kind == "门诊病历").count(), 9);
}

pub const TODAY: &str = "2026-10-22";

/// 两次住院 + 一次急诊(spec §8.2);`doc_indices` 按 stem 对回 `load_corpus` 的下标。
pub fn encounters(corpus: &[Doc]) -> Vec<profile::EncounterRef> {
    let idx = |stems: &[&str]| -> Vec<usize> {
        stems
            .iter()
            .map(|s| {
                corpus
                    .iter()
                    .position(|d| d.stem == *s)
                    .unwrap_or_else(|| panic!("{s}"))
            })
            .collect()
    };
    let d = |s: &str| s.parse::<NaiveDate>().ok();
    vec![
        profile::EncounterRef {
            kind: "inpatient".into(),
            start: d("2024-03-01"),
            end: d("2024-03-10"),
            provider: Some("UF Health Shands".into()),
            title: Some("Discharge Summary".into()),
            doc_indices: idx(&["2024-03-03_手术记录_UF", "2024-03-10_出院记录_UF"]),
        },
        profile::EncounterRef {
            kind: "emergency".into(),
            start: d("2025-06-02"),
            end: d("2025-06-02"),
            provider: Some("UF Health Shands".into()),
            title: Some("ED Visit".into()),
            doc_indices: idx(&["2025-06-02_急诊记录_UF"]),
        },
        profile::EncounterRef {
            kind: "inpatient".into(),
            start: d("2025-06-02"),
            end: d("2025-06-14"),
            provider: Some("UF Health Shands".into()),
            title: Some("Discharge Summary".into()),
            doc_indices: idx(&[
                "2025-06-03_影像报告_UF",
                "2025-06-05_病理报告_UF",
                "2025-06-14_出院记录_UF",
            ]),
        },
    ]
}

/// 同一份语料跑通用层;`pkgs` 是装着的包(开没开由 `events` 决定)。
pub fn render(
    today: &str,
    events: &[parser::ProfileEvent],
    pkgs: &[profile::Package],
) -> serde_json::Value {
    let corpus = load_corpus();
    let docs: Vec<parser::SourceDoc> = corpus
        .iter()
        .enumerate()
        .map(|(i, d)| parser::SourceDoc {
            index: i,
            date: Some(d.date),
            text: &d.text,
            doc_type: Some(doc_type_for(&d.kind).into()),
            title: Some(d.stem.clone()),
            extraction_json: Some(&d.sidecar),
        })
        .collect();
    let encs = encounters(&corpus);
    let view = profile::materialize_generic(&docs, &encs, events, pkgs, today.parse().unwrap());
    serde_json::to_value(&view).unwrap()
}

pub fn section<'a>(view: &'a serde_json::Value, kind: &str) -> &'a serde_json::Value {
    view["sections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["kind"] == kind && s["package_id"] == "general")
        .unwrap_or_else(|| panic!("没有通用段 {kind}"))
}

fn family<'a>(fams: &'a serde_json::Value, key: &str) -> &'a serde_json::Value {
    fams.as_array()
        .unwrap()
        .iter()
        .find(|f| f["key"] == key)
        .unwrap_or_else(|| panic!("没有族 {key}"))
}

fn codes(fam: &serde_json::Value) -> Vec<String> {
    fam["diagnoses"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["code"].as_str().unwrap_or("").to_string())
        .collect()
}

fn lab_keys(fam: &serde_json::Value) -> Vec<String> {
    fam["labs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["key"].as_str().unwrap().to_string())
        .collect()
}

/// 验收 1:族卡 —— 覆盖表生效、同码合并、无码落 uncoded、一条诊断只在一个主族。
#[test]
fn family_cards_group_diagnoses_by_icd() {
    let view = render(TODAY, &[], &[]);
    let s = section(&view, "family_cards");
    assert_eq!(s["id"], "general_families");
    let fams = &s["body"]["families"];
    let cardio = family(fams, "cardio");
    // I35.0 最近 2024-03,超过 12 个月 → 在「更早」的心血管里,不在「现在」。
    assert!(
        !codes(cardio).contains(&"I35.0".into()),
        "{:?}",
        codes(cardio)
    );
    assert!(codes(family(&s["body"]["earlier_families"], "cardio")).contains(&"I35.0".into()));
    assert!(codes(cardio).contains(&"Z95.2".into()));
    assert!(
        codes(cardio).contains(&"Z79.01".into()),
        "Z79.01 长期抗凝 → 心血管"
    );
    let z95 = cardio["diagnoses"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["code"] == "Z95.2")
        .unwrap();
    let texts = z95["texts"].as_array().unwrap();
    assert_eq!(texts.len(), 3, "三种写法同码合并成一条:{texts:?}");
    assert_eq!(z95["doc_count"], 10, "两份出院小结 + 8 次门诊");
    assert_eq!(z95["first_seen"], "2024-03-10");
    assert_eq!(z95["last_seen"], "2026-09-14");
    assert!(!z95["evidence"].as_array().unwrap().is_empty());
    let inf = family(fams, "infection");
    assert_eq!(codes(inf), vec!["B44.1"]);
    assert_eq!(inf["diagnoses"][0]["secondary"], "respiratory");
    let unc = family(fams, "uncoded");
    assert_eq!(unc["diagnoses"][0]["texts"][0], "Hypertension");
    assert_eq!(unc["diagnoses"][0]["code"], serde_json::Value::Null);
    // 一条诊断只归一个主族。
    let mut all: Vec<String> = Vec::new();
    for f in fams.as_array().unwrap() {
        for c in codes(f) {
            if !c.is_empty() {
                assert!(!all.contains(&c), "{c} 出现在两个族");
                all.push(c);
            }
        }
    }
    // 排序:最近出现日倒序;other 倒数第二、uncoded 最后。
    let keys: Vec<&str> = fams
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["key"].as_str().unwrap())
        .collect();
    assert_eq!(keys.last().copied(), Some("uncoded"));
    assert_eq!(keys[0], "cardio", "{keys:?}");
    assert_eq!(cardio["count"], 2, "I35.0 在「更早」,不计入");
    assert_eq!(cardio["last_seen"], "2026-09-14");
}

/// 验收 5:化验小表 —— 值与单位来自同一个 LabPoint;认不出的 key 不出现、不报错。
#[test]
fn family_cards_attach_lab_tables() {
    let view = render(TODAY, &[], &[]);
    let fams = &section(&view, "family_cards")["body"]["families"];
    let cardio = family(fams, "cardio");
    let keys = lab_keys(cardio);
    for k in ["inr", "bnp", "creatinine"] {
        assert!(keys.contains(&k.into()), "{keys:?}");
    }
    assert!(
        !keys.contains(&"digoxin_level".into()),
        "没有数据的 key 不出行"
    );
    let inr = cardio["labs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["key"] == "inr")
        .unwrap();
    assert_eq!(inr["value"], "2.4");
    assert_eq!(inr["date"], "2026-09-14");
    assert_eq!(inr["ref"], "2-3", "区间是解析后的数,与状态行同一个 fmt_num");
    assert!(
        inr["unit"].is_null() || inr["unit"] == "1",
        "{:?}",
        inr["unit"]
    );
    let crea = cardio["labs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["key"] == "creatinine")
        .unwrap();
    assert_eq!(crea["unit"], "mg/dL", "印刷单位配印刷值");
    assert_eq!(crea["value"], "1.1");
    let inf = family(fams, "infection");
    let ik = lab_keys(inf);
    assert!(ik.contains(&"galactomannan".into()), "{ik:?}");
    assert!(ik.contains(&"crp".into()));
    assert!(
        ik.contains(&"voriconazole_level".into()),
        "名字命中 2025-08-18 那条:{ik:?}"
    );
    let gm = inf["labs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["key"] == "galactomannan")
        .unwrap();
    assert_eq!(gm["value"], "0.2");
    assert_eq!(gm["unit"], "index");
    let common: Vec<&str> = section(&view, "family_cards")["body"]["common_labs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["key"].as_str().unwrap())
        .collect();
    assert!(common.contains(&"wbc"), "{common:?}");
    // 每个 ev: 都在依据段里。
    let ev = section(&view, "evidence");
    let ids: Vec<&str> = ev["body"]["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["id"].as_str().unwrap())
        .collect();
    for f in fams.as_array().unwrap() {
        for d in f["diagnoses"].as_array().unwrap() {
            for e in d["evidence"].as_array().unwrap() {
                assert!(ids.contains(&e.as_str().unwrap()), "{e} 不在依据段");
            }
        }
        for l in f["labs"].as_array().unwrap() {
            assert!(ids.contains(&l["evidence"].as_str().unwrap()));
        }
    }
}

fn med_row<'a>(view: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
    section(view, "med_table")["body"]["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["name"] == name)
        .unwrap_or_else(|| panic!("用药表没有 {name}"))
}

/// 验收 2:华法林 —— 最近剂量、记录中自何日起、首次出现、5mg qd / 5 mg daily 不算变化。
#[test]
fn med_table_since_is_start_of_current_dose_run() {
    let view = render(TODAY, &[], &[]);
    let w = med_row(&view, "华法林");
    assert_eq!(w["dose"], "4mg");
    assert_eq!(w["since"], "2025-01-14");
    assert_eq!(w["first_seen"], "2024-03-10");
    assert_eq!(w["last_seen"], "2026-09-14");
    assert_eq!(w["family"], "cardio");
    assert!(w["stopped"].is_null());
    assert!(!w["evidence"].as_array().unwrap().is_empty());
    // 其他字段:词典认不出的原文名照列、族 other;伏立康唑带「抗真菌」小标。
    let z = med_row(&view, "Zebrafoam");
    assert_eq!(z["family"], "other");
    assert_eq!(z["raw_name"], "Zebrafoam");
    let v = med_row(&view, "伏立康唑");
    assert_eq!(v["family"], "infection");
    assert_eq!(v["family_note"], "抗真菌");
}

/// 验收 3:停药只认原文写了的;`d/c summary reviewed`、`stopped smoking` 不触发;
/// 没有任何药因为「清单里不再出现」被标停。
#[test]
fn med_table_marks_only_written_discontinuation() {
    let view = render(TODAY, &[], &[]);
    let v = med_row(&view, "伏立康唑");
    assert_eq!(v["stopped"]["at"], "2025-11-17");
    assert!(v["since"].is_null(), "停了之后「自何日起」留空");
    let ev = section(&view, "evidence");
    let stop_ev = v["stopped"]["evidence"].as_str().unwrap();
    let quote = ev["body"]["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["id"] == stop_ev)
        .unwrap()["quote"]
        .as_str()
        .unwrap();
    assert!(quote.contains("discontinued"), "{quote}");
    let rows = section(&view, "med_table")["body"]["rows"]
        .as_array()
        .unwrap();
    assert_eq!(rows.last().unwrap()["name"], "伏立康唑", "停了的排最后");
    for r in rows {
        if r["name"] != "伏立康唑" {
            assert!(r["stopped"].is_null(), "{} 不该被标停", r["name"]);
        }
    }
    // 泼尼松只出现过一次、之后清单里没有它 —— 不推停药。
    assert!(med_row(&view, "泼尼松")["stopped"].is_null());
    // 审查 C1:「Do not stop taking warfarin」是叮嘱继续吃;「Aspirin stopped; continue metoprolol」
    // 停的是另一味 —— 两条都在 2025-11-17 那份里,华法林与美托洛尔都不许被标停,since 也不重置。
    assert_eq!(med_row(&view, "华法林")["since"], "2025-01-14");
    assert_eq!(med_row(&view, "美托洛尔")["since"], "2024-03-10");
    for l in section(&view, "journey")["body"]["lanes"]
        .as_array()
        .unwrap()
    {
        if l["key"] == "med:warfarin" || l["key"] == "med:metoprolol" {
            assert!(
                l["nodes"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|n| n["kind"] != "stopped"),
                "{l}"
            );
        }
    }
    assert!(!serde_json::to_string(section(&view, "med_table"))
        .unwrap()
        .contains("已停"));
}

/// 验收 4:stale 按 180 天;文案不说「停」。
#[test]
fn med_table_stale_after_180_days() {
    let last = "2026-09-14".parse::<NaiveDate>().unwrap();
    let plus = |n: i64| (last + chrono::Duration::days(n)).to_string();
    let v = render(&plus(181), &[], &[]);
    let m = med_row(&v, "美托洛尔");
    assert_eq!(m["stale"], true);
    assert_eq!(m["days_since"], 181);
    let v = render(&plus(179), &[], &[]);
    assert_eq!(med_row(&v, "美托洛尔")["stale"], false);
    assert_eq!(section(&v, "med_table")["body"]["stale_after_days"], 180);
}

fn lane<'a>(view: &'a serde_json::Value, key: &str) -> &'a serde_json::Value {
    section(view, "journey")["body"]["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["key"] == key)
        .unwrap_or_else(|| panic!("没有泳道 {key}"))
}

fn lane_opt<'a>(view: &'a serde_json::Value, key: &str) -> Option<&'a serde_json::Value> {
    section(view, "journey")["body"]["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["key"] == key)
}

/// 验收 6:进程 —— 住院 2(天数 9/12)、急诊 1、手术 1、影像 1(IMPRESSION 段)、病理 1;
/// 住院/急诊 severity high;用药泳道华法林 5mg → 4mg 两份依据、伏立康唑有停节点。
#[test]
fn journey_lanes_from_encounters_docs_and_meds() {
    let view = render(TODAY, &[], &[]);
    let inp = lane(&view, "enc_inpatient");
    assert_eq!(inp["severity"], "high");
    let nodes = inp["nodes"].as_array().unwrap();
    assert_eq!(nodes.len(), 2);
    assert_eq!(nodes[0]["at"], "2024-03-01");
    assert_eq!(nodes[0]["to"], "2024-03-01 → 2024-03-10 · 住院 9 天");
    assert_eq!(nodes[0]["text"], "UF Health Shands · 2 份");
    assert_eq!(nodes[1]["to"], "2025-06-02 → 2025-06-14 · 住院 12 天");
    let ed = lane(&view, "enc_emergency");
    assert_eq!(ed["severity"], "high");
    assert_eq!(ed["nodes"].as_array().unwrap().len(), 1);
    assert_eq!(lane(&view, "surgery")["nodes"].as_array().unwrap().len(), 1);
    let img = lane(&view, "imaging");
    assert_eq!(img["severity"], "normal");
    let img_text = img["nodes"][0]["text"].as_str().unwrap();
    assert!(
        img_text.starts_with("Cavitary right upper lobe lesion"),
        "{img_text}"
    );
    assert!(!img_text.contains("Electronically"), "{img_text}");
    let path_text = lane(&view, "pathology")["nodes"][0]["text"]
        .as_str()
        .unwrap();
    assert!(
        path_text.starts_with("Invasive fungal infection"),
        "{path_text}"
    );
    // 用药泳道
    let w = lane(&view, "med:warfarin");
    let wn = w["nodes"].as_array().unwrap();
    assert_eq!(wn.len(), 2, "5mg → 4mg 只有一个变化:{wn:?}");
    assert_eq!(wn[1]["kind"], "change");
    assert!(
        wn[1]["from"].as_str().unwrap().starts_with("5mg"),
        "from 是变化前最后一次的原样剂量串:{:?}",
        wn[1]["from"]
    );
    assert_eq!(wn[1]["to"], "4mg");
    assert_eq!(wn[1]["at"], "2025-01-14");
    let v = lane(&view, "med:voriconazole");
    assert!(v["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .any(|n| n["kind"] == "stopped"));
    // 诊断首次出现泳道
    let dx = lane(&view, "dx:cardio");
    assert!(dx["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .any(|n| n["to"].as_str().unwrap().contains("I35.0")));
    // 空道不出。
    assert!(lane_opt(&view, "dx:oncology").is_none());
}

/// 验收 7:每个 ev: 都在依据段;整份依据 span 为 null。
#[test]
fn every_evidence_id_resolves_and_whole_doc_citations_have_no_span() {
    let view = render(TODAY, &[], &[]);
    let ev = section(&view, "evidence");
    let items = ev["body"]["items"].as_array().unwrap();
    let ids: Vec<&str> = items.iter().map(|e| e["id"].as_str().unwrap()).collect();
    let mut referenced: Vec<String> = Vec::new();
    for r in section(&view, "med_table")["body"]["rows"]
        .as_array()
        .unwrap()
    {
        for e in r["evidence"].as_array().unwrap() {
            referenced.push(e.as_str().unwrap().into());
        }
        if let Some(s) = r["stopped"]["evidence"].as_str() {
            referenced.push(s.into());
        }
    }
    for l in section(&view, "journey")["body"]["lanes"]
        .as_array()
        .unwrap()
    {
        for n in l["nodes"].as_array().unwrap() {
            for e in n["evidence"].as_array().unwrap() {
                referenced.push(e.as_str().unwrap().into());
            }
        }
    }
    assert!(!referenced.is_empty());
    for r in &referenced {
        assert!(ids.contains(&r.as_str()), "{r} 不在依据段");
    }
    let inp_ev = lane(&view, "enc_inpatient")["nodes"][0]["evidence"][0]
        .as_str()
        .unwrap();
    let item = items.iter().find(|e| e["id"] == inp_ev).unwrap();
    assert!(item["span"].is_null(), "整份依据 span 为 null:{item}");
    assert_eq!(item["verified"], true);
}

/// Review Focus 4:缺 end / end < start 的住院不出负数,记 1 天。
#[test]
fn inpatient_days_never_negative() {
    let corpus = load_corpus();
    let docs: Vec<parser::SourceDoc> = corpus
        .iter()
        .enumerate()
        .map(|(i, d)| parser::SourceDoc {
            index: i,
            date: Some(d.date),
            text: &d.text,
            doc_type: Some(doc_type_for(&d.kind).into()),
            title: Some(d.stem.clone()),
            extraction_json: None,
        })
        .collect();
    let d = |s: &str| s.parse::<NaiveDate>().ok();
    let encs = vec![
        profile::EncounterRef {
            kind: "inpatient".into(),
            start: d("2024-03-01"),
            end: None,
            provider: None,
            title: None,
            doc_indices: vec![],
        },
        profile::EncounterRef {
            kind: "inpatient".into(),
            start: d("2025-06-14"),
            end: d("2025-06-02"),
            provider: None,
            title: None,
            doc_indices: vec![],
        },
        profile::EncounterRef {
            kind: "inpatient".into(),
            start: d("2026-01-01"),
            end: d("2026-01-01"),
            provider: None,
            title: None,
            doc_indices: vec![],
        },
    ];
    let view = profile::materialize_generic(&docs, &encs, &[], &[], TODAY.parse().unwrap());
    let view = serde_json::to_value(&view).unwrap();
    let nodes = lane(&view, "enc_inpatient")["nodes"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(nodes.len(), 3);
    // 审查 I2:没有出院日(或止早于起)就不编天数,与时间线页「住院 · N 份」同口径。
    assert_eq!(nodes[0]["to"], "2024-03-01 · 住院");
    assert_eq!(nodes[1]["to"], "2025-06-14 · 住院");
    assert_eq!(nodes[2]["to"], "2026-01-01 → 2026-01-01 · 住院 1 天");
}

fn enable_sle() -> Vec<parser::ProfileEvent> {
    vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "sle".into(),
        at: "2024-03-15".into(),
        payload: serde_json::json!({}),
    }]
}

/// 同一份语料外加一条诊断(最后一份门诊正文一行 + 侧文件一条),其余逐字不动。
fn render_with_dx(
    today: &str,
    pkgs: &[profile::Package],
    text: &str,
    icd: &str,
) -> serde_json::Value {
    let mut corpus = load_corpus();
    let last = corpus
        .iter_mut()
        .rev()
        .find(|d| d.kind == "门诊病历")
        .unwrap();
    last.text.push_str(&format!("{text} [{icd}]\n"));
    let mut sidecar: serde_json::Value = serde_json::from_str(&last.sidecar).unwrap();
    sidecar["diagnoses"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({"text": text, "icd": icd}));
    last.sidecar = sidecar.to_string();
    let docs: Vec<parser::SourceDoc> = corpus
        .iter()
        .enumerate()
        .map(|(i, d)| parser::SourceDoc {
            index: i,
            date: Some(d.date),
            text: &d.text,
            doc_type: Some(doc_type_for(&d.kind).into()),
            title: Some(d.stem.clone()),
            extraction_json: Some(&d.sidecar),
        })
        .collect();
    let encs = encounters(&corpus);
    let view = profile::materialize_generic(&docs, &encs, &[], pkgs, today.parse().unwrap());
    serde_json::to_value(&view).unwrap()
}

/// 验收 8 + 9 + 12 一个测试里顺序跑(覆盖层是进程全局,拆开会互相清):
/// 无包无事件 → 通用段照出;装了 SLE 但没有狼疮诊断 → 只有通用段(`enable` 事件也不算);
/// 有 M32 诊断 → 通用在前、包段在后、华法林不受影响、泼尼松仍在用药表(2026-10-23 起不替换);
/// SLE golden 由 golden_sle_course 另守。
#[test]
fn packages_stack_behind_the_general_layer_only_when_they_apply() {
    let pkg = common::full_pkg();
    let kinds = |v: &serde_json::Value| -> Vec<(String, String)> {
        v["sections"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| {
                (
                    s["package_id"].as_str().unwrap().into(),
                    s["kind"].as_str().unwrap().into(),
                )
            })
            .collect()
    };
    // 1. 无包、无事件。
    let bare = render(TODAY, &[], &[]);
    let k = kinds(&bare);
    assert_eq!(
        k.iter().map(|(_, x)| x.as_str()).collect::<Vec<_>>(),
        vec!["family_cards", "med_table", "journey", "evidence"]
    );
    assert!(k.iter().all(|(p, _)| p == "general"));
    assert_eq!(bare["package_id"], "general");
    assert_eq!(bare["enabled"], true);
    assert!(bare["sources"].as_array().unwrap().is_empty());
    assert!(bare.get("packages").is_none(), "没装包就没有 packages 键");
    // 2. 装了 SLE、甚至写过 enable,但 Jane 没有狼疮诊断:sections 与 1 逐字节相同。
    let installed = render(TODAY, &enable_sle(), std::slice::from_ref(&pkg));
    assert_eq!(
        installed["sections"], bare["sections"],
        "没命中的包一段都不出"
    );
    assert_eq!(installed["packages"][0]["applies"], false);
    assert_eq!(installed["packages"][0]["family"], "immune");
    // 3. 有 M32 诊断:通用在前、包段在后。
    terminology::set_overlay(common::overlay_entries(&pkg));
    let both = render_with_dx(
        TODAY,
        std::slice::from_ref(&pkg),
        "Lupus nephritis",
        "M32.14",
    );
    terminology::set_overlay(vec![]);
    let k = kinds(&both);
    assert_eq!(&k[..4], &kinds(&bare)[..]);
    assert!(k[4..].iter().all(|(p, _)| p == "sle"), "{k:?}");
    assert!(k[4..].iter().any(|(_, x)| x == "state"));
    assert!(!both["sources"].as_array().unwrap().is_empty());
    assert_eq!(both["packages"][0]["applies"], true);
    let w = med_row(&both, "华法林");
    assert_eq!(w["since"], "2025-01-14");
    assert!(
        med_row(&both, "泼尼松")["dose"].is_string(),
        "包段在「现在」、药表在「用药」,不在同一屏,泼尼松行不替换"
    );
    // 审查 I1:通用段与包段共用一本依据簿 —— 同一个 ev: id 在所有 evidence 段里只能对应一句话,
    // 且包段引用的每个 ev: 都查得到。
    let mut quote_of: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    for s in both["sections"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["kind"] == "evidence")
    {
        for e in s["body"]["items"].as_array().unwrap() {
            let id = e["id"].as_str().unwrap().to_string();
            let q = e["quote"].as_str().unwrap_or("").to_string();
            if let Some(prev) = quote_of.insert(id.clone(), q.clone()) {
                assert_eq!(prev, q, "{id} 在两段里指向不同的话");
            }
        }
    }
    let mut referenced: Vec<String> = Vec::new();
    for s in both["sections"].as_array().unwrap() {
        if s["package_id"] != "sle" || s["kind"] == "evidence" {
            continue;
        }
        let body = serde_json::to_string(&s["body"]).unwrap();
        for (i, _) in body.match_indices("\"ev:") {
            let rest = &body[i + 1..];
            referenced.push(rest[..rest.find('"').unwrap()].to_string());
        }
    }
    assert!(!referenced.is_empty());
    for r in &referenced {
        assert!(quote_of.contains_key(r), "{r} 查不到");
    }
}

/// 返回 `true` = 这次是重写 golden(调用方在全部写完后再 panic 提醒 review)。
fn check_golden(got: serde_json::Value, file: &str) -> bool {
    let golden_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("testdata")
        .join(file);
    if std::env::var("UPDATE_GOLDEN").is_ok() {
        std::fs::write(
            &golden_path,
            serde_json::to_string_pretty(&got).unwrap() + "\n",
        )
        .unwrap();
        return true;
    }
    let want: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&golden_path).expect("golden 文件在"))
            .expect("golden 是合法 JSON");
    assert_eq!(
        got, want,
        "通用层 ProfileView 变了;确认是有意的再 UPDATE_GOLDEN=1 重生成"
    );
    false
}

#[test]
fn the_jane_course_renders_the_pinned_generic_view() {
    let wrote = check_golden(render(TODAY, &[], &[]), "golden_generic_view.json");
    assert!(
        !wrote,
        "golden 已重写 —— 人工 review 这次 diff 之后再跑一遍(不带 UPDATE_GOLDEN)"
    );
}

// ─────────────────────────── 「现在」只留最近 12 个月(2026-10-23 spec §4.1) ───────────────────────────

fn all_codes(fams: &serde_json::Value) -> Vec<String> {
    fams.as_array()
        .unwrap()
        .iter()
        .flat_map(|f| codes(f))
        .collect()
}

#[test]
fn diagnoses_older_than_recent_days_go_to_earlier_families() {
    // Jane:I35.0 最近 2024-03;Z95.2 最近 2026-09-14。today = 2026-10-22 → I35.0 在「更早」。
    let view = render(TODAY, &[], &[]);
    let body = &section(&view, "family_cards")["body"];
    let recent = all_codes(&body["families"]);
    let earlier = all_codes(&body["earlier_families"]);
    assert!(recent.contains(&"Z95.2".to_string()), "{recent:?}");
    assert!(!recent.contains(&"I35.0".to_string()), "{recent:?}");
    assert!(earlier.contains(&"I35.0".to_string()), "{earlier:?}");
    // 同一个码不会两边都在。
    for c in &recent {
        assert!(!earlier.contains(c), "{c} 两边都出现");
    }
    // 「更早」不算化验、不参与族 count。
    for f in body["earlier_families"].as_array().unwrap() {
        assert!(f["labs"].as_array().unwrap().is_empty());
    }
    assert_eq!(body["recent_days"], profile::RECENT_DAYS);
}

#[test]
fn recent_window_boundary_is_inclusive_at_365_days() {
    // Z95.2 最近 2026-09-14:today = +365 天 还在「现在」;+366 天 进「更早」。
    let at = |today: &str| {
        let view = render(today, &[], &[]);
        let body = &section(&view, "family_cards")["body"];
        (
            all_codes(&body["families"]),
            all_codes(&body["earlier_families"]),
        )
    };
    let (r, e) = at("2027-09-14");
    assert!(r.contains(&"Z95.2".to_string()) && !e.contains(&"Z95.2".to_string()));
    let (r, e) = at("2027-09-15");
    assert!(!r.contains(&"Z95.2".to_string()) && e.contains(&"Z95.2".to_string()));
}
