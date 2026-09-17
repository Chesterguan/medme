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

/// 把几行医嘱包成一份处方笺文本(`extract_meds` 只在 `doc_type` 含 prescription
/// 时整份跑,见 `parser::aggregate::wants_meds`)。
pub fn rx_doc(rows: &str) -> String {
    format!("处方笺\nRp:\n{rows}\n")
}

/// 带完整 SLE 活动度规则的夹具包(8 条,权重与阈值逐字取自 sle-clinical-sources
/// §B.1/§B.2)。Task 18 的真包与这份**内容一致**,由那边的 pin 测试钉住。
pub fn activity_pkg() -> Package {
    serde_json::from_str(ACTIVITY).expect("夹具包必须解析")
}

/// 把 `(日期, 文本)` 列表变成 `SourceDoc`。文本**借**调用方那一份(元组里的
/// `String` 自己就是所有者),不复制也不泄漏 —— 调用方只要让 `docs` 活到用完,
/// 借用检查自然成立。
/// `doc_type` 与 `title` 都按**首行**认:首行含「处方」→ 处方笺,否则化验单。
/// 这不是凑测试 —— `parser::aggregate` 的两道门控正好相反(`extract_labs` 只跑
/// 化验单类,`extract_meds` 只整份跑处方类),夹具统一给 `lab_report` 的话,
/// 处方永远抽不出药来。
pub fn mk_docs<'a>(docs: &'a [(&str, String)]) -> Vec<parser::SourceDoc<'a>> {
    docs.iter()
        .enumerate()
        .map(|(i, (d, t))| {
            let head = t.lines().next().unwrap_or_default();
            parser::SourceDoc {
                index: i,
                date: d.parse().ok(),
                text: t,
                doc_type: Some(if head.contains("处方") {
                    "prescription".into()
                } else {
                    "lab_report".into()
                }),
                title: Some(head.to_string()),
                extraction_json: None,
            }
        })
        .collect()
}

/// 夹具包 = [`ACTIVITY`] 再加 `rules.states`(下面那两张表)、`drugs`、
/// `rules.targets` 与两张卡的标题。**不另抄一份 `ACTIVITY`** —— 两份活动度规则
/// 会各自长歪。Task 14–16 继续往同一份里加 `monitoring` / `milestones`。
pub fn full_pkg() -> Package {
    serde_json::from_value(full_json()).expect("夹具包必须解析")
}

/// [`full_pkg`] 的 JSON 形态,给要改几个字段再用的用例(改包的用例改这份,别另抄)。
pub fn full_json() -> serde_json::Value {
    let mut v: serde_json::Value = serde_json::from_str(ACTIVITY).expect("夹具包必须解析");
    v["rules"]["states"] = serde_json::from_str(STATES).expect("达标表必须解析");
    v["rules"]["targets"] = serde_json::from_str(TARGETS).expect("目标值必须解析");
    v["drugs"] = serde_json::from_str(DRUGS).expect("药物表必须解析");
    let sections = v["views"]["sections"]
        .as_array_mut()
        .expect("views.sections 是数组");
    sections.push(serde_json::json!({"kind":"status_card","title":"现行方案"}));
    sections.push(serde_json::json!({"kind":"checklist","title":"达标情况(逐条对照)"}));
    v
}

/// spec §2 的 `drugs` 那一份,**但 `pred_equiv` 与 `pred_equiv_source` 都是
/// `null`**:等效换算表在 sle-clinical-sources §G 里还没核到原始出处(2020 指南
/// 表2「常用糖皮质激素的等效剂量」我们没读到),global-constraints 说没核实的数值
/// 一律 `null`。Task 19 核完才填,填上以后引擎那条「只认泼尼松本身」的分支自然
/// 不再触发。
pub const DRUGS: &str = r#"[
  {"class":"gc","atc_prefix":"H02AB","names":["泼尼松","泼尼松龙","甲泼尼龙","地塞米松"],
   "pred_equiv":null,"pred_equiv_source":null},
  {"class":"hcq","atc_prefix":"P01BA02","names":["羟氯喹","硫酸羟氯喹","纷乐"]},
  {"class":"mmf","names":["吗替麦考酚酯","霉酚酸酯","骁悉"]},
  {"class":"aza","names":["硫唑嘌呤"]},
  {"class":"ctx","names":["环磷酰胺"]},
  {"class":"mtx","names":["甲氨蝶呤"]},
  {"class":"cni","names":["他克莫司","环孢素","伏环孢素"]},
  {"class":"belimumab","names":["贝利尤单抗","倍力腾"],
   "infusion":{"iv":"第 0、2、4 周,之后每 4 周","sc":"每周 200 mg(狼疮肾炎为每周 400 mg×4 次后改 200 mg)"}},
  {"class":"telitacicept","names":["泰它西普","泰爱"],"infusion":{"sc":"每周 160 mg"}},
  {"class":"rtx","names":["利妥昔单抗","美罗华"]}]"#;

/// 治疗目标值(§C.3 / §C.4)。两份指南的激素维持线**都带**,因为它们不一样:
/// 界面只画一条就是替医生挑了一份指南。`label` 里是源文逐字片段 + 年份。
///
/// 羟氯喹那条的 `label_rule` 是**国内说明书原文**(§D.2.1,0.2 g 规格):6.5 mg/kg
/// 理想体重,与指南的 5 mg/kg 真实体重既不同数也不同基准。源文件把它标成
/// 「VERBATIM(page-summariser; verify)」—— 还没有人对着纸核过,所以
/// `verify_status` 是 `pending`,界面上必须说出这一点,**且它只显示、不参与任何
/// 判定**(`mg_per_kg` 永远只跟指南值比)。
pub const TARGETS: &str = r#"{
  "gc":[{"value":7.5,"label":"EULAR 2019:less than 7.5 mg/day (prednisone equivalent)","source":"S3"},
        {"value":5,"label":"EULAR 2023:≤5 mg/day (prednisone equivalent)","source":"S4"}],
  "hcq":{"target":5,"unit":"mg/kg/d","basis":"真实体重(real body weight)","target_source":"S4",
         "label_rule":{"text":"不应超过6.5mg/kg/日（自理想体重而非实际体重算得）或400mg/日",
                       "verify_status":"pending","source":"S_HCQ_INSERT"}}}"#;

/// DORIS 2021(§C.1)与 LLDAS(§C.2)两张表,逐条取自 sle-clinical-sources 的
/// VERBATIM 行。`<0.5` / `<5` 按 DORIS Box 1 原文,中国 2025 指南的 `≤` 写进
/// `note` —— 恰好在边界上时两份指南不一致,这件事要在界面上说出来。
pub const STATES: &str = r#"[{"id":"doris","label":"DORIS 2021 缓解标准(逐条对照,不下结论)","source":"S5",
  "items":[
    {"id":"csledai_zero","label":"临床 SLEDAI = 0(去掉补体、dsDNA 两项)","kind":"csledai_eq",
     "value":0,"exclude":["low_complement","dsdna_high"],"source":"S5",
     "note":"Box 1 原文只说「irrespective of serology」;落到低补体、dsDNA 升高这两行,是按 §B.1 里仅有的两条血清学描述符推出来的对应(源里标 PARAPHRASE),待 Task 19 核"},
    {"id":"phga","label":"医生整体评估 PhGA(0–3 分)< 0.5","kind":"pga_lt","value":0.5,"source":"S5",
     "note":"DORIS Box 1 原文是 <0.5 (0–3);中国 2025 指南写 ≤0.5,恰好等于 0.5 时两份不一致"},
    {"id":"pred","label":"泼尼松/泼尼松龙(或等效)< 5 mg/天","kind":"pred_lt","value":5,"source":"S5",
     "note":"DORIS Box 1 原文是 prednisolone(泼尼松龙)<5 mg/day;中国 2025 指南写 prednisone(泼尼松)≤5 mg/d —— 药名与边界两份都不一样"},
    {"id":"therapy","label":"允许用羟氯喹、低剂量激素、稳定的免疫抑制剂或生物制剂",
     "kind":"manual","source":"S5"}]},
 {"id":"lldas","label":"LLDAS 低疾病活动(逐条对照,不下结论)","source":"S6",
  "items":[
    {"id":"sledai_le4","label":"SLEDAI-2K ≤ 4","kind":"sledai_le","value":4,"source":"S6"},
    {"id":"no_major_organ","label":"肾、中枢、心肺、血管炎、发热均无活动,无溶血性贫血与消化道活动",
     "kind":"manual","source":"S6"},
    {"id":"pga_le1","label":"SELENA-SLEDAI PGA(0–3 分)≤ 1","kind":"pga_le","value":1,"source":"S6"},
    {"id":"pred_le75","label":"泼尼松龙(或等效)≤ 7.5 mg/天","kind":"pred_le","value":7.5,"source":"S6",
     "note":"§C.2 原文是 prednisolone (or equivalent) ≤7.5 mg daily"},
    {"id":"no_new","label":"与上次评估相比没有新的狼疮活动表现","kind":"manual","source":"S6"},
    {"id":"stable_therapy","label":"免疫抑制剂与已获批生物制剂维持在耐受良好的标准维持剂量(不含研究用药)",
     "kind":"manual","source":"S6",
     "note":"§C.2 第 (5) 条原文:「well-tolerated standard maintenance doses of immunosuppressive drugs and approved biologic agents, excluding investigational drugs」"}]}]"#;

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
