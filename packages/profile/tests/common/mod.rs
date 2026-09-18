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

/// 包 `terms.analytes` → 运行时术语覆盖层的条目。**真机上这一步是 Task 20 的 FFI
/// 在装包时做的**,测试里手动做一遍 —— 不做的话包自己定义的分析物(尿红细胞/尿白
/// 细胞按高倍视野计数)连认都认不出来,用到它们的规则一律出「未知」。
///
/// `category` 固定 `lab`:包的 `terms.analytes` 只能定义化验项(药物走 `drugs[]`),
/// 这不是从包里读出来的,所以也不该由包说了算。
pub fn overlay_entries(pkg: &Package) -> Vec<terminology::Entry> {
    pkg.terms
        .analytes
        .iter()
        .map(|a| {
            serde_json::from_value(serde_json::json!({
                "key": a.key, "canonical_name": a.name, "category": "lab",
                "panel": a.panel, "codes": {}, "canonical_unit": a.canonical_unit,
                "units": a.units.iter().map(|u| serde_json::json!(
                    {"unit": u.unit, "slope": u.slope, "intercept": u.intercept})).collect::<Vec<_>>(),
                "aliases": a.aliases,
            }))
            .expect("覆盖层条目必须解析")
        })
        .collect()
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
    v["markers"] = serde_json::from_str(MARKERS).expect("指标表必须解析");
    v["terms"]["analytes"] = serde_json::from_str(PKG_ANALYTES).expect("包内分析物必须解析");
    v["rules"]["states"] = serde_json::from_str(STATES).expect("达标表必须解析");
    v["rules"]["targets"] = serde_json::from_str(TARGETS).expect("目标值必须解析");
    v["rules"]["monitoring"] = serde_json::from_str(MONITORING).expect("复查提醒规则必须解析");
    v["rules"]["milestones"] = serde_json::from_str(MILESTONES).expect("里程碑规则必须解析");
    v["drugs"] = serde_json::from_str(DRUGS).expect("药物表必须解析");
    // 规则里引用到的出处都得在 `manifest.sources` 里声明,否则 `ProfileView.sources`
    // 解不出来,界面上那个出处 id 点开是空的(`reminders.rs` 的守卫用例钉住这件事)。
    let sources = v["manifest"]["sources"]
        .as_array_mut()
        .expect("manifest.sources 是数组");
    for (id, cite) in SOURCES {
        sources.push(serde_json::json!({"id": id, "cite": cite, "url": null}));
    }
    let sections = v["views"]["sections"]
        .as_array_mut()
        .expect("views.sections 是数组");
    sections.push(serde_json::json!({"kind":"status_card","title":"现行方案"}));
    sections.push(serde_json::json!({"kind":"checklist","title":"达标情况(逐条对照)"}));
    sections.push(serde_json::json!({"kind":"reminders","title":"待补 / 逾期"}));
    sections.push(serde_json::json!({"kind":"series_chart","title":"指标趋势"}));
    // 哪几类事件标红是**包**说的(spec §6「复发标红」),不是引擎自己认定的临床
    // 判断 —— 没点名的类型一律 `normal`。
    sections.push(serde_json::json!({"kind":"timeline","title":"病程时间轴",
                                     "severity_high":["flare","hospitalization"]}));
    // 第二块 `checklist`(里程碑)靠 `id` 与达标表区分 —— 两块复用同一套渲染,
    // 标题按 kind 取的话谁在前谁就顶掉另一个(见 `rules::view_title`)。
    sections.push(serde_json::json!({"kind":"checklist","id":"ln_milestones",
                                     "title":"狼疮肾炎治疗里程碑"}));
    v
}

/// spec §2 的 `markers`(12 条,逐字)。`group` 没写的按 `role` 分组。
pub const MARKERS: &str = r#"[
  {"key":"complement_c3","role":"activity","dir":"low_is_active","group":"补体"},
  {"key":"complement_c4","role":"activity","dir":"low_is_active","group":"补体"},
  {"key":"anti_dsdna","role":"serology","dir":"high_is_active","qualitative_ok":true},
  {"key":"urine_pcr","role":"organ:kidney","dir":"high_is_active"},
  {"key":"urine_protein_24h","role":"organ:kidney","dir":"high_is_active"},
  {"key":"wbc","role":"activity"},{"key":"plt","role":"activity"},
  {"key":"esr","role":"inflammation"},{"key":"crp","role":"inflammation"},
  {"key":"creatinine","role":"organ:kidney"},{"key":"egfr","role":"organ:kidney"},
  {"key":"alt","role":"drug_monitor"},{"key":"ast","role":"drug_monitor"}]"#;

/// 包里自己定义的分析物(spec §2 的 `terms.analytes`)。UPCR 写这份夹具时内置词典
/// 里还没有;Task 17 把 `urine_pcr` 补成了**内置**条目,所以这份定义现在的角色反过来了
/// —— 它是「包定义了一个内置已有的 key」那种情况:别名可以加,`name`/`loinc`/`units`
/// 一律以内置为准(`terminology::set_overlay` 的红线)。这条夹具因此顺带钉着
/// `marker_name` 的内置优先。
/// ⚠️ `urine_rbc_hpf` / `urine_wbc_hpf` 的别名**故意不写「尿红细胞」「尿白细胞」**:
/// 内置词典里有按**体积**计数的 `urine_rbc_count`(/uL),而「每高倍视野几个」与它
/// 没有确定换算(词典 `stool_wbc` 那条 note 是同一条理由)。包抢不走内置的别名
/// (`terminology::pick_best` 的内置优先),写上去只会让这一项在有些报告上悄悄
/// 解析成另一个概念 —— 所以别名按中国尿沉渣报告单印的那几种写法给。
pub const PKG_ANALYTES: &str = r#"[
  {"key":"urine_pcr","name":"尿蛋白/肌酐比值","loinc":"2890-2","panel":"肾功能",
   "canonical_unit":"mg/g","units":[{"unit":"mg/mmol","slope":8.84,"intercept":0}],
   "aliases":["尿蛋白肌酐比","UPCR","尿蛋白/肌酐"],"note":"待核 LOINC"},
  {"key":"urine_rbc_hpf","name":"尿红细胞(高倍视野)","panel":"尿液",
   "canonical_unit":"/[HPF]","units":[{"unit":"/[HPF]","slope":1,"intercept":0},
                                      {"unit":"/HP","slope":1,"intercept":0}],
   "aliases":["高倍镜下红细胞","镜检红细胞","尿沉渣镜检红细胞"],
   "note":"与内置按体积计数的尿红细胞(/uL)之间没有确定换算,故另立一条"},
  {"key":"urine_wbc_hpf","name":"尿白细胞(高倍视野)","panel":"尿液",
   "canonical_unit":"/[HPF]","units":[{"unit":"/[HPF]","slope":1,"intercept":0},
                                      {"unit":"/HP","slope":1,"intercept":0}],
   "aliases":["高倍镜下白细胞","镜检白细胞","尿沉渣镜检白细胞"],
   "note":"同上"}]"#;

/// [`STATES`] / [`TARGETS`] / [`MONITORING`] 里引用到的出处,`id` 与
/// `.superpowers/sdd/disease-profile/sle-clinical-sources.md` 里的编号一一对应。
/// [`ACTIVITY`] 自带的 `S1` 不在这里(那份壳自己声明了)。
pub const SOURCES: [(&str, &str); 10] = [
    ("S3", "EULAR 2019 SLE recommendations, Ann Rheum Dis 2019"),
    ("S4", "EULAR 2023 update, Ann Rheum Dis 2024"),
    (
        "S8",
        "EULAR recommendations for the management of SLE with kidney involvement: 2025 update, Ann Rheum Dis 2026;85:75–90(doi 10.1016/j.ard.2025.09.007)",
    ),
    ("S5", "DORIS 2021 definition of remission, Box 1"),
    ("S6", "LLDAS, Franklyn et al. 2016"),
    (
        "S10",
        "2020 中国系统性红斑狼疮诊疗指南(Rheumatol Immunol Res 2020;1(1):5–23)推荐 3",
    ),
    (
        "S_MMF_LABEL",
        "CELLCEPT US prescribing information §5.4(DailyMed 37241e87-4af4-4dc3-a1aa-ea6f20d8dc40)",
    ),
    (
        "S_GC_EULAR2007",
        "EULAR recommendations on management of systemic glucocorticoid therapy, Ann Rheum Dis 2007;66:1560–7, Rec 6a",
    ),
    ("S_HCQ_INSERT", "硫酸羟氯喹片说明书(0.1 g / 0.2 g 两种规格)"),
    (
        "S_ACR_GIOP2022",
        "ACR 2022 glucocorticoid-induced osteoporosis guideline, Arthritis Care Res 2023;75:2405–19",
    ),
];

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

/// 复查提醒规则(§A.1 / §D.1 / §D.2.1 / §D.3)。**只有三种 kind,没有第四种**:
/// 引擎永远不会按单项化验指标造复查间隔 —— §A.1「最重要的负面发现」写得很清楚,
/// 中国 2020/2025 与 EULAR 都没给 dsDNA/补体/尿蛋白/血常规任何单项间隔。
///
/// `verify_status` 是 **fail-closed** 的(见 `rules::monitor_pending`):只有逐字
/// `"verified"` 的那几条才会被算成到期日,其余一律只显示、不到期。这里两条 pending
/// 就是源文件里核不实的那两条 —— 说明书自相矛盾的羟氯喹眼科间隔、只核到第三方摘要
/// 页的骨密度/FRAX 那句。
pub const MONITORING: &str = r#"[
  {"kind":"disease_cadence","id":"visit_active","state":"active","every_days":30,
   "panel_keys":["complement_c3","complement_c4","anti_dsdna","urine_protein_24h","wbc","plt"],
   "text":"该复诊了,活动期一般一个月看一次,复诊时通常会查补体、抗 dsDNA、尿蛋白和血常规",
   "basis":"guideline","source":"S10","verify_status":"verified",
   "note":"中国 2020 与 2025 指南推荐 3 同一句逐字:活动期「at least every month」/「at least once a month for patients with active SLE」"},
  {"kind":"disease_cadence","id":"visit_stable","state":"stable","every_days":90,
   "panel_keys":["complement_c3","complement_c4","anti_dsdna","urine_protein_24h","wbc","plt"],
   "text":"该复诊了,稳定期一般 3—6 个月看一次,复诊时通常会查补体、抗 dsDNA、尿蛋白和血常规",
   "basis":"guideline","source":"S10","verify_status":"verified",
   "note":"逐字是「once every 3 to 6 months for patients with stable SLE」。区间取更密的一端(3 个月)提醒:早提醒只是多跑一趟,晚提醒会漏掉复发"},
  {"kind":"drug_schedule","id":"mmf_cbc","drug_class":"mmf","target":"血常规",
   "panel_keys":["wbc","plt","hgb"],
   "phases":[{"until_days":30,"every_days":7},
             {"until_days":90,"every_days":14},
             {"until_days":365,"every_days":30},
             {"every_days":30,"basis":"package_default","verify_status":"pending",
              "note":"⚠️ 第一年之后说明书没再给任何间隔。这一档是包作者按每月沿用的**外推**,所以它以自己的身份出去(package_default + 待核):只显示、不算到期。待 Task 19 逐条核"}],
   "text":"吃吗替麦考酚酯期间该查血常规了",
   "basis":"label","source":"S_MMF_LABEL","verify_status":"verified",
   "note":"CELLCEPT 说明书 §5.4 逐字:「weekly for the first month, twice monthly for the second and third months, and monthly for the remainder of the first year」"},
  {"kind":"drug_schedule","id":"hcq_eye","drug_class":"hcq","target":"眼科检查(眼底/OCT/视野)",
   "exam_names":["眼底","OCT","视野"],"phases":[],
   "text":"羟氯喹的眼科检查间隔几份来源互相矛盾,下次门诊问一下医生多久查一次",
   "basis":"label","source":"S_HCQ_INSERT","verify_status":"pending",
   "note":"§D.2.1:0.1 g 规格说明书写「定期(每3月)」、0.2 g 规格写「每年至少一次」,两份说明书自己都对不上,且都只经摘要管道;指南侧是「低危第 5 年起每年」。没有一个能逐字确定的间隔,所以只显示、不算到期"},
  {"kind":"drug_threshold","id":"gc_ca_vitd","drug_class":"gc",
   "min_daily_pred_equiv":7.5,"min_days":91,
   "action":"该补钙和维生素 D 了,下次门诊问一下医生",
   "basis":"guideline","source":"S_GC_EULAR2007","verify_status":"verified",
   "note":"EULAR 2007 全身激素治疗推荐 6a 逐字:「If a patient is started on prednisone ⩾7.5 mg daily and continues on prednisone for more than 3 months, calcium and vitamin D supplementation should be prescribed.」。原文是 more than 3 months(超过、不含),所以下限写 91 天而不是 90 —— `min_days` 在引擎里是「至少这么多天」(含)"},
  {"kind":"drug_threshold","id":"gc_dxa_frax","drug_class":"gc",
   "min_daily_pred_equiv":2.5,"min_days":91,"min_age":40,
   "action":"做一次骨密度 / FRAX 骨折风险评估",
   "basis":"guideline","source":"S_ACR_GIOP2022","verify_status":"pending",
   "note":"人群定义「>3 months treatment with GCs ≥2.5 mg daily」是 ACR 2022 GIOP 摘要逐字;但「≥40 岁用 FRAX + 骨密度筛查」那句只核到第三方摘要页、没核到指南原文(§D.1),所以整条 pending"}]"#;

/// 狼疮肾炎治疗里程碑(spec §5.5),逐条取自 sle-clinical-sources §E.1/§E.2 里标
/// **VERBATIM** 的行。每条带 `source` 与 `year`:同一个概念在 2019/2023/2025 三份
/// 指南里是三个数(§E.2 的 ⚠️ 框),不带年份的阈值说不清自己是哪一份的。
///
/// `from` 是**起算日(T0)的口径**,写在每条自己身上:`rules.milestones` 是个数组,
/// 没有块级配置的位置,而每条自带起算日的好处是界面能逐行说出「这一条从哪天起算」。
///
/// 「3/6/12 个月」→ 90/180/365 天是**包里的换算**,源文只写 months —— 所以写进
/// `note`,别让它看起来像指南给的天数。
pub const MILESTONES: &str = r#"[
  {"id":"upr_drop_25_3m","kind":"proteinuria_drop_pct","label":"3 个月蛋白尿较基线下降 ≥25%",
   "any_of":["urine_protein_24h","urine_pcr"],"drop_pct":25,"by_days":90,
   "from":{"organ":"kidney","baseline_window_days":30,
           "drug_classes":["mmf","aza","ctx","mtx","cni","belimumab","telitacicept","rtx"]},
   "source":"S8","year":2025,
   "note":"§E.2 rec 2 逐字:「a reduction in proteinuria of at least 25% by 3 months (2b/C), 50% by 6 months (2a/B), and a UPCR target <700 mg/g by 12 months (1b/B)」。「3 个月」按 90 天算是包里的换算,原文只写 months。24h 尿蛋白与 UPCR 各自跟自己的基线比,不合并"},
  {"id":"upr_drop_50_6m","kind":"proteinuria_drop_pct","label":"6 个月蛋白尿较基线下降 ≥50%(部分应答)",
   "any_of":["urine_protein_24h","urine_pcr"],"drop_pct":50,"by_days":180,
   "from":{"organ":"kidney","baseline_window_days":30,
           "drug_classes":["mmf","aza","ctx","mtx","cni","belimumab","telitacicept","rtx"]},
   "source":"S8","year":2025,
   "note":"§E.2 叙述逐字把这一档称作 partial response:「the goals of 25% reduction by 3 months, 50% by 6 months (partial response)」。「6 个月」按 180 天算是包里的换算"},
  {"id":"upcr_below_700_12m","kind":"upcr_below","label":"12 个月 UPCR <700 mg/g",
   "key":"urine_pcr","threshold":700,"canonical_unit":"mg/g","by_days":365,
   "from":{"organ":"kidney","drug_classes":["mmf","aza","ctx","mtx","cni","belimumab","telitacicept","rtx"]},
   "source":"S8","year":2025,
   "note":"§E.2 逐字:「an absolute UPCR value of <700 mg/g at 12 months remained unchanged; a change from the range of 500 to 700 mg (referred in the 2019 recommendations) was decided for the sake of simplification」。EULAR 2023 复述 2019 时写的是 500–700 mg/day,与这一条不是同一个数。「12 个月」按 365 天算是包里的换算"},
  {"id":"upcr_below_500_any","kind":"upcr_below","label":"完全肾应答:任一时点 UPCR <500 mg/g",
   "key":"urine_pcr","threshold":500,"canonical_unit":"mg/g",
   "source":"S8","year":2025,
   "note":"§E.2 逐字:「Complete renal response should be defined as UPCR <500 mg/g at any time point.」KDIGO 2024(Figure 11)的完全缓解口径是 PCR <0.5 g/g = 同一个数,但它另外要求肾功能在基线 ±10%–15% 内 —— 那一半在 gfr_80_baseline 那条(两份指南的肾功能条件本身也不一样,§E.2 的 ⚠️ 框)"},
  {"id":"upr24_below_500_any","kind":"upcr_below","label":"旧口径(EULAR 2019):24 小时尿蛋白 <500 mg",
   "key":"urine_protein_24h","threshold":500,"canonical_unit":"mg/24h",
   "source":"S3","year":2019,
   "note":"§E.2 逐字:「complete renal remission (proteinuria <500 mg/24 hours and SCr within 10% from baseline)」。⚠️ 这一条只答**蛋白尿那一半**:另一半「肌酐在基线 10% 以内」与 EULAR 2025 的「GFR ≥ 基线 80%」是两把不同的尺,包里不把它们混成一条。2019 与 2025 的单位也不同(mg/24h vs mg/g),所以另立一条、各带各的年份"},
  {"id":"gfr_80_baseline","kind":"gfr_pct_of_baseline","label":"GFR 维持在基线的 ≥80%",
   "key":"egfr","pct":80,"source":"S8","year":2025,
   "note":"§E.2 逐字:「stabilisation (if not improvement) of GFR to ≥80% of baseline value is desirable within the first 3 months」。⚠️ EULAR 2019/2023 用的是另一把尺(SCr within 10% from baseline),KDIGO 2024 是 ±10%–15% —— 三份不一致(§E.2 的 ⚠️ 框)。基线 = 档案里最早一次有日期的 eGFR"},
  {"id":"biopsy_indication","kind":"biopsy_indication","label":"肾活检指征:蛋白尿 ≥0.5 g/24h 或 UPCR ≥500 mg/g",
   "any_of":[{"key":"urine_protein_24h","threshold":0.5,"canonical_unit":"g/24h"},
             {"key":"urine_pcr","threshold":500,"canonical_unit":"mg/g"}],
   "source":"S8","year":2025,
   "note":"§E.1 rec 1 逐字:「Kidney biopsy is recommended in every patient with evidence of kidney involvement, especially in those with persistent proteinuria (≥0.5 g/24 h or urine protein-creatinine ratio [UPCR] ≥500 mg/g) (2b/B)」。原文紧接着说这是 indicative threshold:「the 0.5 g/d threshold should be kept as an indicative threshold to avoid potentially unnecessary biopsies, while not preventing biopsies at lower levels of proteinuria, if indicated」。⚠️ 「persistent(持续)」原文没给次数或天数,这一条看的是**最近一次**结果,不代表指南意义上的「持续」;中国 2019 狼疮肾炎指南同一处写的是严格大于(>0.5 g/24 h、>500 mg/g),恰好等于时两份不一致"}]"#;

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
