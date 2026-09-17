//! 测试共用夹具。**不要**在这里塞断言或规则逻辑 —— 它只造输入。
//!
//! 这个文件被**每个**集成测试二进制各编一份,所以「本文件里没人用」对任何一个
//! 二进制都成立 —— 不 allow 就会在只用了一半夹具的那些二进制里报 dead_code。
#![allow(dead_code)]
use profile::Package;

/// 一个签好名的最小包(与 `package.rs` 单测里的 MINIMAL 同一份内容)。
pub fn minimal_pkg() -> Package {
    serde_json::from_str(MINIMAL).expect("夹具包必须解析")
}

pub const MINIMAL: &str = r#"{"manifest":{"id":"t","family":"immune","version":"2026.09.1","min_engine":1,
  "display":{"name":"测试病","short":"测试"},"disclaimer":"仅整理你的病历,不做诊断",
  "sources":[{"id":"S1","cite":"test","url":null}]},
  "triggers":{"diagnosis_patterns":[],"serology_any_two":[]},
  "terms":{"aliases":{},"analytes":[]},"markers":[],"drugs":[],
  "rules":{"activity":{"window_days":10,"max":18,"items":[]},"states":[],"monitoring":[],"milestones":[]},
  "views":{"sections":[],"handoff":[]}}"#;

/// 一份长得像化验单的文本,用来证明「没开启就不算」不是因为没有输入。
pub fn sle_like_doc() -> String {
    "检验报告单\n补体C3 0.42 g/L 0.9-1.8 L\n补体C4 0.06 g/L 0.1-0.4 L\n".to_string()
}

/// 活动度用例统一的「今天」。窗口边界(前 10 天)全部相对它算。
pub const TODAY: &str = "2026-09-16";

/// 把几行化验包成一份像样的报告单文本(`extract_labs` 要看到报告的样子)。
pub fn lab_doc(rows: &str) -> String {
    format!("检验报告单\n项目 结果 单位 参考区间\n{rows}\n")
}

/// 带完整 SLE 活动度规则的夹具包(8 条,权重与阈值逐字取自 sle-clinical-sources
/// §B.1/§B.2)。Task 18 的真包与这份**内容一致**,由那边的 pin 测试钉住。
pub fn activity_pkg() -> Package {
    serde_json::from_str(ACTIVITY).expect("夹具包必须解析")
}

/// 把 `(日期, 文本)` 列表变成 `SourceDoc`。文本**借**调用方那一份(元组里的
/// `String` 自己就是所有者),不复制也不泄漏 —— 调用方只要让 `docs` 活到用完,
/// 借用检查自然成立。
pub fn mk_docs<'a>(docs: &'a [(&str, String)]) -> Vec<parser::SourceDoc<'a>> {
    docs.iter()
        .enumerate()
        .map(|(i, (d, t))| parser::SourceDoc {
            index: i,
            date: d.parse().ok(),
            text: t,
            doc_type: Some("lab_report".into()),
            title: None,
            extraction_json: None,
        })
        .collect()
}

/// 夹具包 = [`ACTIVITY`] 再加 `rules.states`(下面那两张表)与 checklist 的标题。
/// **不另抄一份 `ACTIVITY`** —— 两份活动度规则会各自长歪。Task 13–16 继续往同一
/// 份里加 `monitoring` / `milestones`。
pub fn full_pkg() -> Package {
    let mut v: serde_json::Value = serde_json::from_str(ACTIVITY).expect("夹具包必须解析");
    v["rules"]["states"] = serde_json::from_str(STATES).expect("达标表必须解析");
    v["views"]["sections"]
        .as_array_mut()
        .expect("views.sections 是数组")
        .push(serde_json::json!({"kind":"checklist","title":"达标情况(逐条对照)"}));
    serde_json::from_value(v).expect("夹具包必须解析")
}

/// DORIS 2021(§C.1)与 LLDAS(§C.2)两张表,逐条取自 sle-clinical-sources 的
/// VERBATIM 行。`<0.5` / `<5` 按 DORIS Box 1 原文,中国 2025 指南的 `≤` 写进
/// `note` —— 恰好在边界上时两份指南不一致,这件事要在界面上说出来。
pub const STATES: &str = r#"[{"id":"doris","label":"DORIS 2021 缓解标准(逐条对照,不下结论)","source":"S5",
  "items":[
    {"id":"csledai_zero","label":"临床 SLEDAI = 0(去掉补体、dsDNA 两项)","kind":"csledai_eq",
     "value":0,"exclude":["low_complement","dsdna_high"],"source":"S5"},
    {"id":"phga","label":"医生整体评估 PhGA < 0.5","kind":"pga_lt","value":0.5,"source":"S5",
     "note":"DORIS Box 1 原文是 <0.5;中国 2025 指南写 ≤0.5,恰好等于 0.5 时两份不一致"},
    {"id":"pred","label":"泼尼松 < 5 mg/天","kind":"pred_lt","value":5,"source":"S5",
     "note":"DORIS Box 1 原文是 <5 mg/d;中国 2025 指南写 ≤5 mg/d"},
    {"id":"therapy","label":"允许用羟氯喹、低剂量激素、稳定的免疫抑制剂或生物制剂",
     "kind":"manual","source":"S5"}]},
 {"id":"lldas","label":"LLDAS 低疾病活动(逐条对照,不下结论)","source":"S6",
  "items":[
    {"id":"sledai_le4","label":"SLEDAI-2K ≤ 4","kind":"sledai_le","value":4,"source":"S6"},
    {"id":"no_major_organ","label":"肾、中枢、心肺、血管炎、发热均无活动,无溶血性贫血与消化道活动",
     "kind":"manual","source":"S6"},
    {"id":"pga_le1","label":"SELENA-SLEDAI PGA(0–3 分)≤ 1","kind":"pga_le","value":1,"source":"S6"},
    {"id":"pred_le75","label":"泼尼松(或等效)≤ 7.5 mg/天","kind":"pred_le","value":7.5,"source":"S6"},
    {"id":"no_new","label":"与上次评估相比没有新的狼疮活动表现","kind":"manual","source":"S6"}]}]"#;

/// 与 [`MINIMAL`] 同一个壳,只把 `rules.activity` 填满。section 的标题在
/// `views.sections` 里(spec §6:标题全来自包,引擎里不写死)。
pub const ACTIVITY: &str = r#"{"manifest":{"id":"t","family":"immune","version":"2026.09.1","min_engine":1,
  "display":{"name":"测试病","short":"测试"},"disclaimer":"仅整理你的病历,不做诊断",
  "sources":[{"id":"S1","cite":"test","url":null}]},
  "triggers":{"diagnosis_patterns":[],"serology_any_two":[]},
  "terms":{"aliases":{},"analytes":[]},"markers":[],"drugs":[],
  "rules":{"activity":{"window_days":10,"max":18,"items":[
   {"id":"low_complement","label":"低补体","weight":2,"kind":"flag_low",
    "any_of":["complement_c3","complement_c4","ch50"],"source":"S1"},
   {"id":"dsdna_high","label":"dsDNA 升高","weight":2,"kind":"flag_high","any_of":["anti_dsdna"],
    "qualitative_positive":["阳性","强阳性","+"],
    "caveat":"表格原文写的是 Farr 法;中国实验室多用 ELISA/CLIFT,按定义存在偏差","source":"S1"},
   {"id":"proteinuria","label":"蛋白尿","weight":4,"kind":"gt","key":"urine_protein_24h",
    "threshold":0.5,"canonical_unit":"g/24h","source":"S1"},
   {"id":"hematuria","label":"血尿","weight":4,"kind":"gt","key":"urine_rbc_hpf","threshold":5,
    "canonical_unit":"/[HPF]","caveat":"需排除结石、感染或其它原因,需医生确认","source":"S1"},
   {"id":"pyuria","label":"脓尿","weight":4,"kind":"gt","key":"urine_wbc_hpf","threshold":5,
    "canonical_unit":"/[HPF]","caveat":"需排除感染,需医生确认","source":"S1"},
   {"id":"casts","label":"管型","weight":4,"kind":"text_present",
    "patterns":["红细胞管型"],
    "note":"§B.1 的描述符是「Heme-granular or red blood cell casts.」。红细胞管型有 §A.3 的 VERBATIM 中文写法;含血颗粒管型那一半没有 —— 「颗粒管型」比 heme-granular 宽(发热/脱水/运动后都可见),不是这条描述符,故不入。待 Task 19 核到中文写法再补",
    "source":"S1"},
   {"id":"leukopenia","label":"白细胞减少","weight":1,"kind":"lt","key":"wbc","threshold":3.0,
    "canonical_unit":"10*9/L","source":"S1"},
   {"id":"thrombocytopenia","label":"血小板减少","weight":1,"kind":"lt","key":"plt","threshold":100,
    "canonical_unit":"10*9/L","source":"S1"}]},"states":[],"monitoring":[],"milestones":[]},
  "views":{"sections":[{"kind":"score_card","title":"活动度(化验可算部分)"}],"handoff":[]}}"#;
