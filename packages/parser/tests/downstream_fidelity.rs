//! 量化「对齐错 → 渲染错 → 趋势错」这条因果链的**下游两级**:假设 OCR 文本
//! 完全正确,从文本到「医生看到的摘要 / 用户看到的趋势」这条路上还有没有失真?
//!
//! ## 为什么这条能与 OCR 干净隔离
//!
//! `tests/fixtures/corpus/` 下的 21 份 `.txt` **不经 OCR**,是张建国这个纵向病例
//! 的真值文本(`examples/demo-dataset/generate.sh` 逐字生成,`corpus_summary.rs`
//! 模块头已有说明,不在本文件重复)。喂给这些文本的任何错,都是
//! `parser::labs` / `parser::aggregate` / `parser::assemble_summary` 自己的,
//! 与 `packages/ocr` 认字对不对无关——本文件不碰、也不需要碰那个包。
//!
//! ## 三级量化结果(2026-08,cargo test -p parser)
//!
//! | 级 | 结论 | 证据 |
//! |---|---|---|
//! | ① 化验抽取 | **干净**:6 份化验单印的 42 条,42 条全部抽出、全部命中词典 analyte_key,值/单位/参考区间/flag 逐条与原文核对无误 | [`lab_report_rows_all_match_the_printed_ground_truth`] |
//! | ② 趋势序列(化验) | **干净**:14 条序列的点数与「谁印了这项」逐份核对完全吻合,没有该连的断开、也没有不该连的连上 | [`analyte_series_point_counts_match_hand_counted_ground_truth`] |
//! | ② 趋势序列(诊断) | **有真实缺陷**:诊断名里带逗号的括注(`(不稳定型心绞痛,PCI 术后)`)被 `split_inline` 当成分隔符切开,一条诊断炸成三条问题泳道,其中一条是无意义碎片 | [`comma_inside_a_diagnosis_parenthetical_fragments_one_condition_into_three`] |
//! | ③ 医生摘要 | **直接继承②的缺陷**:`assemble_summary` 的 `problems[]` 里真的出现了一条名叫「PCI 术后)」的泳道,与一条名字带孤悬左括号的泳道,和一条完整的——同一次住院,同一个诊断,医生看到三条 | [`assemble_summary_shows_the_fragmented_diagnosis_as_three_problem_lanes`] |
//! | 附:静默数据丢失 | **有真实缺陷,与上面三级并列、更隐蔽**:家庭血压/血糖自测日记(扫描件常见形态)整份文档抽出 0 个趋势点——9 次血压、9 次心率、9 次血糖全部消失,没有任何报错 | [`home_monitoring_diary_yields_zero_trend_points`] |
//!
//! ## 严重度排序(供后续决定修不修、先修哪个;本轮不动实现)
//!
//! 1. **P0·诊断炸裂**(②③):doc_type 与化验抽取的正确性反而让这个缺陷更显眼——
//!    读者已经确认「化验没问题」,再看到医生泳道里蹦出一条「PCI 术后)」,信任
//!    受损的方式和 fabricated lab value 是同一类:**看起来像真数据,其实是解析
//!    产物**。根因在 `parser::handoff::split_inline`(逗号分隔符,不认括号语境),
//!    与诊断名里带逗号的括注同时出现才触发——真实中文出院小结的诊断列表常见
//!    写法(`病名(分型,处置)`),不是这份语料特有的巧合。
//! 2. **P1·家庭监测日记全丢**:静默,无报错,无部分抽取——用户会以为「拍了就存
//!    了」。根因有两层,`labs.rs` 模块头已经写明是**故意**的设计边界(`血压
//!    120/80` 这种比值形态、以及以日期开头的行会被 `row_re` 的名字必须含字母
//!    这条门槛拒掉),所以这不是一个隐藏 bug,而是一个产品决策文档(`MANUAL-
//!    ENTRY-DESIGN.md`)目前只覆盖了「App 内手输」这一种自测数据来源、没覆盖
//!    「拍下纸质日记导入」这一种的**产品缺口**——本文件把它钉成可复现的数字,
//!    修不修、怎么修留给产品判断。
//! 3. **不是缺陷,是已知且已有测试覆盖的限制**:诊断名之间只用空格分隔(无逗号
//!    顿号)时三条诊断挤成一条 —— `conditions.rs` 的
//!    `space_separated_inline_diagnoses_stay_one_term` 已经钉住,本文件里
//!    `2025-12-03_处方_扫描件.txt` 恰好在真语料里复现了这个已知形状,顺带在
//!    [`analyte_series_point_counts_match_hand_counted_ground_truth`] 的姊妹测试
//!    里记一笔,不重复开新测试。
//! 4. **化验抽取/趋势序列(labs)**:本语料下没找到缺陷。但这不是「结构上不可能
//!    出错」——`GroupKey::Raw(raw_name)` 对未归一化的化验按**原始名**归组
//!    (`aggregate.rs`),同一个指标如果两份报告拼写不同又都没进词典,会分成两条
//!    线而不是连成一条;本语料的 6 份化验单全部用同一套拉丁缩写(TC/TG/Cr/…),
//!    从未触发这条路径。这是 `radical_glyphs_impact.rs` 里
//!    `labs_are_nearly_untouched_because_the_corpus_prints_latin_abbreviations`
//!    已经写明的同一个「语料运气」,这里不重新量化、只指出它对趋势序列同样成立。

use parser::{aggregate, assemble_summary, SourceDoc};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

/// 原样载入 21 份真值 corpus,`(文件名不带扩展名, 全文)`,按文件名排序 ——
/// 与 `corpus_summary.rs::corpus()` 同一份数据、同一种读法,互不依赖。
fn corpus() -> Vec<(String, String)> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/corpus");
    let mut docs: Vec<(String, String)> = std::fs::read_dir(&dir)
        .expect("corpus fixtures are checked in next to this test")
        .filter_map(|e| {
            let p = e.ok()?.path();
            if p.extension()? != "txt" {
                return None;
            }
            let name = p.file_stem()?.to_str()?.to_string();
            Some((name, std::fs::read_to_string(&p).ok()?))
        })
        .collect();
    docs.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        docs.len(),
        21,
        "corpus 份数变了 —— 本文件的手工核对基准(逐份读原文数出来的化验行数/\
         序列点数)是按当前 21 份核的,份数一变基准就得重新核,不能沿用旧数字"
    );
    docs
}

/// 走与 `corpus_summary.rs` 完全相同的路径产出 `SourceDoc`:`classify` 定
/// `doc_type`、`guess_date` 定日期——与手机端 `pipeline::ingest` 用的是同一对
/// 函数,这里不是另起一条自造的路径。
fn source_docs(raw: &[(String, String)]) -> Vec<SourceDoc<'_>> {
    raw.iter()
        .enumerate()
        .map(|(i, (name, text))| SourceDoc {
            index: i,
            date: parser::guess_date(text).map(|d| d.date_naive()),
            text: text.as_str(),
            doc_type: Some(format!("{:?}", parser::classify(text)).to_lowercase()),
            title: Some(name.clone()),
        })
        .collect()
}

// ===========================================================================
// ① 化验抽取:逐条对照原文手工读出的真值
// ===========================================================================

/// 语料里 6 份「检验报告」各自印了几条化验行——逐份打开原文数出来的,不是从
/// 代码反推的。挑出来的几条关键值/单位/参考区间/flag 在
/// `lab_values_units_and_flags_match_the_source_document_verbatim` 里逐条核对
/// 过,这里只钉行数,细节见那个测试。
const LAB_REPORT_ROW_COUNTS: &[(&str, usize)] = &[
    ("2023-06-15_检验报告_血脂血糖", 8), // TC TG HDL-C LDL-C GLU HbA1c Cr BUN
    ("2024-01-15_检验报告_血脂", 6),     // TC TG HDL-C LDL-C GLU HbA1c
    ("2024-05-18_检验报告_肾功血糖", 6), // Cr BUN UA eGFR GLU HbA1c
    ("2025-05-06_检验报告_血脂血糖", 6), // TC TG HDL-C LDL-C GLU HbA1c
    ("2025-11-05_检验报告_血常规肾功能", 8), // WBC NEUT% HGB PLT Cr BUN UA eGFR
    ("2026-02-14_检验报告_肾功血脂", 8), // Cr BUN UA eGFR TC LDL-C TG HbA1c
];

/// **①级主断言**:6 份化验单印的 42 条,`aggregate()` 的真实调用路径
/// (`doc_type` 门控 + `wants_labs`,与 `pipeline::ingest` 同一套)一条不多、
/// 一条不少地抽出来,并且每一条都命中了词典(`analyte_key.is_some()`)——
/// 抽出来但没归一化的化验,`AnalyteSeries` 里会单独按 `GroupKey::Raw` 归组,
/// 不会悄悄混进已归一化的那条线,但这里干脆一条没有。
///
/// 同时钉住一条**反向**护栏:化验单原文之外的 15 份非化验文档(出院记录/
/// 门诊病历/处方/影像/病理/心电图/家庭监测)贡献的化验条数必须是 0——`labs.rs`
/// 单跑(不经 `doc_type` 门控)时,叙述性文字会被 `row_re` 读成貌似合理的化验行
/// (例如既往史里的「高血压 10 年」「最高 175/105 mmHg」读成 raw_name=「既往史:
/// 高血压」value=10 unit=「175/105」,病理报告的「肉眼所见:灰白色黏膜组织 3cm」
/// 读成 value=3 unit=「cm。」还配上一对臆造的参考区间——都是真实跑出来的现象,
/// 不是假设)。真实路径没有这个问题,是因为 `aggregate()` 按 `doc_type` 挡在了
/// 门外(非化验文档只会从 `化验`/`检验` 一类小节标题下取文本,这 15 份都没有
/// 这种标题);这条测试钉住的是**这道门今天挡住了**,不是「叙述性文字本来就
/// 不会被读错」——两者是完全不同的两个断言,后者已经被证伪。
#[test]
fn lab_report_rows_all_match_the_printed_ground_truth() {
    let raw = corpus();
    let docs = source_docs(&raw);
    let agg = aggregate(&docs);

    let expected_total: usize = LAB_REPORT_ROW_COUNTS.iter().map(|(_, n)| n).sum();
    let extracted_total: usize = agg.labs.iter().map(|s| s.points.len()).sum();
    assert_eq!(
        extracted_total,
        expected_total,
        "6 份化验单合计印了 {expected_total} 条,真实路径抽出 {extracted_total} 条\
         (序列: {:?})",
        agg.labs
            .iter()
            .map(|s| (s.group_name.clone(), s.points.len()))
            .collect::<Vec<_>>()
    );
    assert!(
        agg.labs.iter().all(|s| s.analyte_key.is_some()),
        "有序列没能归一化到词典(analyte_key = None),42 条基线要求全部命中: {:?}",
        agg.labs
            .iter()
            .filter(|s| s.analyte_key.is_none())
            .map(|s| s.group_name.clone())
            .collect::<Vec<_>>()
    );

    // 每份化验单单独核一次行数,定位比只看总数更快。
    let by_source: BTreeMap<usize, &str> = raw
        .iter()
        .enumerate()
        .map(|(i, (name, _))| (i, name.as_str()))
        .collect();
    let mut per_doc_counts: BTreeMap<&str, usize> = BTreeMap::new();
    for s in &agg.labs {
        for p in &s.points {
            *per_doc_counts.entry(by_source[&p.source]).or_insert(0) += 1;
        }
    }
    for (name, expected) in LAB_REPORT_ROW_COUNTS {
        let got = per_doc_counts.get(name).copied().unwrap_or(0);
        assert_eq!(
            got, *expected,
            "{name}:原文印了 {expected} 条,抽出 {got} 条"
        );
    }
    // 15 份非化验文档贡献的化验条数必须是 0 —— 见上面的文档注释。
    let lab_report_names: std::collections::HashSet<&str> =
        LAB_REPORT_ROW_COUNTS.iter().map(|(n, _)| *n).collect();
    for (name, count) in &per_doc_counts {
        assert!(
            lab_report_names.contains(name),
            "非化验文档「{name}」贡献了 {count} 条化验——叙述性文字漏过了 doc_type 门控"
        );
    }
}

/// **①级细节断言**:抽出来的值/单位/参考区间/flag 逐条与原文核对,挑最容易
/// 出错、最影响临床结论的几条(而不是全部 42 条——行数已经在上一条测试钉住)。
/// 每条断言旁边引用原文那一行。
#[test]
fn lab_values_units_and_flags_match_the_source_document_verbatim() {
    let raw = corpus();
    let docs = source_docs(&raw);
    let agg = aggregate(&docs);
    let by_key = |k: &str| {
        agg.labs
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some(k))
            .unwrap_or_else(|| panic!("no series for {k}"))
    };

    // "Cr(Creatinine) 肌酐    108   umol/L   57 - 97   ↑" —— 名字里带英文全称加
    // 括号加中文,行号剥离/术语解析都没被这个形状绊倒。
    // (2025-11-05_检验报告_血常规肾功能.txt)
    let cr = by_key("creatinine");
    let p_20251105 = cr
        .points
        .iter()
        .find(|p| p.date == Some(chrono::NaiveDate::from_ymd_opt(2025, 11, 5).unwrap()))
        .expect("2025-11-05 creatinine point");
    assert_eq!(p_20251105.value, 108.0);
    assert_eq!(p_20251105.flag.as_deref(), Some("H"));

    // 肌酐四份报告连续上升 95→104→108→112,与 2026-02-14 报告自己文字里写的
    // 「肌酐持续缓慢上升(2023年95→2024年104→2025年108→2026年112 umol/L)」逐字吻合——
    // 这句话本身也在同一份报告的叙述段里,而这段叙述没有被误读成化验行(见上一
    // 条测试的反向护栏)。
    let mut cr_series: Vec<f64> = cr.points.iter().map(|p| p.value).collect();
    cr_series.sort_by(|a, b| a.partial_cmp(b).unwrap());
    assert_eq!(cr_series, vec![95.0, 104.0, 108.0, 112.0]);

    // "eGFR   估算肾小球滤过率   63   ml/min/1.73m2   > 90   ↓" —— 单侧参考
    // (只有下限)、单位里带自由斜杠和小数点(`1.73m2`),没有被参考区间正则
    // 误吞。(2026-02-14_检验报告_肾功血脂.txt)
    let egfr = by_key("egfr");
    let p = egfr
        .points
        .iter()
        .find(|p| p.date == Some(chrono::NaiveDate::from_ymd_opt(2026, 2, 14).unwrap()))
        .expect("2026-02-14 egfr point");
    assert_eq!(p.value, 63.0);
    assert_eq!(p.unit.as_deref(), Some("ml/min/1.73m2"));
    assert_eq!(p.flag.as_deref(), Some("L"));
    assert_eq!(egfr.ref_low, Some(90.0));
    assert_eq!(egfr.ref_high, None);

    // "TC   总胆固醇 Cholesterol   5.20   mmol/L   < 5.20   正常" —— 值卡在
    // 参考上限本身,报告自己标「正常」,解析结果与原文一致而不是被 `< 5.20`
    // 的严格不等号带偏成「偏高」。(2025-05-06_检验报告_血脂血糖.txt)
    let tc = by_key("cholesterol");
    let p = tc
        .points
        .iter()
        .find(|p| p.date == Some(chrono::NaiveDate::from_ymd_opt(2025, 5, 6).unwrap()))
        .expect("2025-05-06 TC point");
    assert_eq!(p.value, 5.20);
    assert_eq!(p.flag.as_deref(), Some("N"));

    // 只测过 HDL 三份(2026-02-14 那份报告没印 HDL-C 这一行——真值本来就没有,
    // 不是漏抽)。
    let hdl = by_key("hdl");
    assert_eq!(hdl.points.len(), 3);
}

// ===========================================================================
// ② 趋势序列:同一指标跨文档能不能连成一条线(labs 干净;诊断有真实缺陷)
// ===========================================================================

/// 14 条化验序列的点数,与「翻开 6 份化验单原文、数每个分析物出现在哪几份」
/// 逐一核对——不是从 `aggregate()` 的输出反推期望值。见上面 `LAB_REPORT_ROW_
/// COUNTS` 旁的注释重建每份报告印了哪些项。
const ANALYTE_SERIES_POINT_COUNTS: &[(&str, usize)] = &[
    ("cholesterol", 4),   // 06-15 01-15 05-06 02-14(11-05 不测血脂)
    ("triglycerides", 4), // 同上
    ("hdl", 3),           // 06-15 01-15 05-06(02-14 报告没印 HDL-C 这行)
    ("ldl", 4),           // 06-15 01-15 05-06 02-14
    ("glucose", 4),       // 06-15 01-15 05-18 05-06(11-05/02-14 不测空腹血糖)
    ("hba1c", 5),         // 06-15 01-15 05-18 05-06 02-14(11-05 血常规单不测)
    ("creatinine", 4),    // 06-15 05-18 11-05 02-14(01-15/05-06 血脂单不测肌酐)
    ("urea", 4),          // 同 creatinine 四份
    ("uric_acid", 3),     // 05-18 11-05 02-14
    ("egfr", 3),          // 同 uric_acid 三份
    ("wbc", 1),           // 仅 2025-11-05 那份血常规单
    ("neut_pct", 1),
    ("hgb", 1),
    ("plt", 1),
];

/// **②级主断言(labs 干净)**:14 条序列一条不多一条不少,点数逐条吻合,且序列
/// 集合本身就是 14 条——既没有该连成一条却断成两条(同一分析物两个
/// `GroupKey`),也没有不该连却连上(两个不同分析物落进同一条序列)。
#[test]
fn analyte_series_point_counts_match_hand_counted_ground_truth() {
    let raw = corpus();
    let docs = source_docs(&raw);
    let agg = aggregate(&docs);

    assert_eq!(
        agg.labs.len(),
        ANALYTE_SERIES_POINT_COUNTS.len(),
        "序列条数变了(现在 {}, 手工核对基准 {})——要么多连了要么少连了,先看下面\
         逐条断言定位是哪个分析物: {:?}",
        agg.labs.len(),
        ANALYTE_SERIES_POINT_COUNTS.len(),
        agg.labs
            .iter()
            .map(|s| (s.analyte_key.clone(), s.points.len()))
            .collect::<Vec<_>>()
    );
    for (key, expected) in ANALYTE_SERIES_POINT_COUNTS {
        let series = agg
            .labs
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some(*key));
        match series {
            None => panic!("分析物 {key} 没有对应序列——本该出现在 {expected} 份报告里"),
            Some(s) => assert_eq!(
                s.points.len(),
                *expected,
                "{key}:手工核对 {expected} 个点,序列里 {} 个",
                s.points.len()
            ),
        }
    }
}

/// **②级缺陷(诊断,不是 labs)**:`2026-07-15_出院记录_冠脉支架术后.txt` 的
/// 出院诊断行——
/// `出院诊断:1. 冠状动脉粥样硬化性心脏病(不稳定型心绞痛,PCI 术后)  2. 高血压…`
/// ——诊断名的括注里带了一个逗号(`不稳定型心绞痛,PCI 术后`,常见的「分型,处置」
/// 写法)。`handoff::split_inline` 先按行内编号切开五条诊断,再对每一段无条件
/// 按 `；;，,、` 切一遍——第二刀不认括号语境,把第一段从逗号处切成了两截:
///
/// - `冠状动脉粥样硬化性心脏病(不稳定型心绞痛` —— 左括号孤悬,一个不平衡的
///   诊断名,`icd_paren_re` 因为末尾不是 `)` 提取不出(伪)ICD 码,原样进
///   `raw_text`。
/// - `PCI 术后)` —— 右括号孤悬,一个无意义碎片,被当成独立诊断收进
///   `AggregatedCondition`。
///
/// 同一份文档的入院诊断行(`入院诊断:冠状动脉粥样硬化性心脏病(不稳定型心绞痛)`,
/// 没有逗号,括号配对)正常抽出完整诊断名,三条 `raw_text` 于是同时存在。
///
/// 这条测试钉住**现状**(缺陷成立),不是期望值——`comma_inside_a_diagnosis_
/// parenthetical_is_not_mistaken_for_a_separator` 这个名字如果哪天测试改成
/// 断言只有一条干净的诊断,说明 `split_inline` 学会了跳过括号内的逗号,这条
/// 测试要跟着改成正面断言。
#[test]
fn comma_inside_a_diagnosis_parenthetical_fragments_one_condition_into_three() {
    let raw = corpus();
    let docs = source_docs(&raw);
    let agg = aggregate(&docs);

    let texts: Vec<&str> = agg.conditions.iter().map(|c| c.raw_text.as_str()).collect();

    assert!(
        texts.contains(&"冠状动脉粥样硬化性心脏病(不稳定型心绞痛)"),
        "完整、括号配对的诊断名(来自入院诊断行)应该存在: {texts:?}"
    );
    assert!(
        texts.contains(&"冠状动脉粥样硬化性心脏病(不稳定型心绞痛"),
        "已知缺陷:出院诊断行的逗号把诊断名从括注中间切断,留下孤悬左括号的\
         残缺名——这条断言如果失败说明缺陷已经不在了,把这个测试改成反向断言: {texts:?}"
    );
    assert!(
        texts.contains(&"PCI 术后)"),
        "已知缺陷:上面那次切断的另一半——一个带孤悬右括号的无意义碎片,被当成\
         独立诊断收了进来: {texts:?}"
    );

    // 三条 raw_text 全部来自同一份文档(index 20 = 2026-07-15_出院记录_冠脉支架术后),
    // 印证这不是三个不同诊断,是一个诊断被切成了三份记录。
    let idx = |t: &str| {
        agg.conditions
            .iter()
            .find(|c| c.raw_text == t)
            .map(|c| c.sources.clone())
    };
    assert_eq!(
        idx("冠状动脉粥样硬化性心脏病(不稳定型心绞痛)"),
        Some(vec![20])
    );
    assert_eq!(
        idx("冠状动脉粥样硬化性心脏病(不稳定型心绞痛"),
        Some(vec![20])
    );
    assert_eq!(idx("PCI 术后)"), Some(vec![20]));
}

/// **已知且已有测试覆盖的限制,不是新缺陷**——`2025-12-03_处方_扫描件.txt`
/// 的诊断行 `诊断:2型糖尿病 糖尿病肾病(早期) 高血压3级` 只用空格分隔三条诊断
/// (常见于「扫描件」这种版式信息丢失更多的输入),`conditions.rs` 的
/// `space_separated_inline_diagnoses_stay_one_term` 单元测试已经用几乎相同的
/// 字符串钉住了这个行为;这里只确认真语料真的走到了这条路径,不重新展开
/// 论证——见 `conditions.rs` 那条测试的文档注释。
#[test]
fn space_separated_diagnosis_line_from_a_real_scanned_prescription_stays_one_term() {
    let raw = corpus();
    let docs = source_docs(&raw);
    let agg = aggregate(&docs);

    let merged = agg
        .conditions
        .iter()
        .find(|c| c.raw_text == "2型糖尿病 糖尿病肾病(早期) 高血压3级");
    assert!(
        merged.is_some(),
        "2025-12-03_处方_扫描件.txt 的空格分隔诊断行应该原样合成一条(已知限制,\
         见 conditions.rs::space_separated_inline_diagnoses_stay_one_term): {:?}",
        agg.conditions
            .iter()
            .map(|c| c.raw_text.as_str())
            .collect::<Vec<_>>()
    );
}

// ===========================================================================
// ③ 医生摘要:②级的诊断缺陷有没有一路传到 `assemble_summary` 的 `problems[]`
// ===========================================================================

fn problems(sm: &Value) -> Vec<&Value> {
    sm.get("problems")
        .and_then(Value::as_array)
        .map(|a| a.iter().collect())
        .unwrap_or_default()
}

fn term_of(p: &Value) -> &str {
    p.get("term").and_then(Value::as_str).unwrap_or("")
}

/// **③级断言**:②级钉住的诊断炸裂,原样出现在医生实际看到的 `problems[]`
/// 数组里——同一次住院、同一个诊断,查看器会渲染出三条问题泳道,其中一条
/// 泳道的标题字面意思是「PCI 术后)」,读起来像一个诊断,其实是解析产物。
/// `merge_conditions`(`handoff.rs`)按 `condition_key` 归并同义变体,但
/// `condition_key` 只处理 `problem_map.json` 里已知的疾病别名和几个手工维护
/// 的词干(`DISEASE_STEMS`),对这三条互不包含的字符串无能为力——它们不是
/// 同义词,是同一句话被切断后的三个不同片段,合并逻辑设计上就管不到这种情况。
#[test]
fn assemble_summary_shows_the_fragmented_diagnosis_as_three_problem_lanes() {
    let raw = corpus();
    let docs = source_docs(&raw);
    let sm = assemble_summary(&docs);
    let probs = problems(&sm);
    let terms: Vec<&str> = probs.iter().map(|p| term_of(p)).collect();

    assert!(
        terms.contains(&"PCI 术后)"),
        "已知缺陷:医生摘要里出现了一条标题是解析碎片的泳道,不是被过滤掉了: {terms:?}"
    );
    assert!(
        terms.contains(&"冠状动脉粥样硬化性心脏病(不稳定型心绞痛"),
        "已知缺陷:医生摘要里还有一条标题带孤悬左括号的残缺诊断名: {terms:?}"
    );
    assert!(
        terms.contains(&"冠状动脉粥样硬化性心脏病(不稳定型心绞痛)"),
        "完整版本也在,三条并存,不是三选一: {terms:?}"
    );

    // 三条泳道都没有挂上任何化验/用药——这是另一个已知、有据可查的限制
    // (`problem_map.json` 里的疾病名是「冠心病」,`match_disease` 只做双向子串
    // 匹配、没有同义词表,`WORKLIST.md` #3 记录着 `fix/disease-synonyms` 分支
    // 因为会把糖尿病泳道整条打空而被拒绝合入)——就算三条炸裂的泳道合并成一条
    // 干净的完整诊断名,`match_disease("冠状动脉粥样硬化性心脏病(不稳定型心绞痛)")`
    // 依然不会命中「冠心病」。两个缺陷相互独立,修其中一个不会连带修好另一个。
    for t in [
        "PCI 术后)",
        "冠状动脉粥样硬化性心脏病(不稳定型心绞痛",
        "冠状动脉粥样硬化性心脏病(不稳定型心绞痛)",
    ] {
        let p = probs.iter().find(|p| term_of(p) == t).unwrap();
        assert_eq!(
            p.get("labs").and_then(Value::as_array).map(Vec::len),
            Some(0),
            "{t} 不该挂上化验(问题映射表里没有能对上号的疾病名)"
        );
        assert_eq!(
            p.get("meds").and_then(Value::as_array).map(Vec::len),
            Some(0),
            "{t} 不该挂上用药"
        );
    }
}

// ===========================================================================
// 附:静默数据丢失 —— 家庭监测日记整份文档 0 个趋势点
// ===========================================================================

/// **附加发现**:`2026-04-30_血压记录_家庭监测.txt`
/// (`examples/demo-dataset/generate.sh` #20,「home vitals log, txt」)是一份
/// 患者自己记录一个月血压/心率/血糖的日记,9 行读数,列对齐工整、没有任何
/// OCR 噪声(真值文本)。`parser::classify` 把它判成 `Other`(不是
/// `LabReport`,标题/正文都没有「化验」「检验」这类关键词,分类本身诚实)。
///
/// `aggregate()` 对 `doc_type` 不是 lab 的文档只从 `化验`/`检验` 一类小节标题
/// 下取文本(`sections_text(text, SecKind::Labs)`)——这份日记整篇没有这种标题,
/// 于是这条路径贡献 0 条化验。**就算**这份文档被判成 `LabReport`、走整篇抽取,
/// 表格每一行仍然会被拒收:行首是纯数字日期(`2026-04-01  06:50    138/86 …`),
/// `labs.rs::row_re` 非贪婪匹配会把「2026-04-01」当成「名字」,`parse_line` 随即
/// 因为「名字不含字母」整行判 `Nothing`;血压本身又是 `120/80` 这种比值形态,
/// `labs.rs` 模块头「Deliberately NOT handled」一节写明这是刻意排除在外的形状。
/// 两道门都不是这条测试要修的对象——它们是 `labs.rs` 已经写明的设计边界,这里
/// 只是第一次把「一份真实存在的文档类型,结果是 0」量化下来,写进
/// `MANUAL-ENTRY-DESIGN.md` 的产品决策目前只覆盖了 App 内手输的自测数据,没有
/// 覆盖「拍下纸质日记导入」这一种来源——静默,不报错,用户不会知道数据没进去。
///
/// 这不是「产品没想过这份数据」——`apps/mobile_flutter/rust/src/api/vault.rs`
/// 的 `HOME_MONITORING_READINGS` 逐日期、逐数值与这份 `.txt` 完全相同(同一
/// 组 9 天血压/心率/血糖),移动端 demo 数据就是用它,只是**走的是结构化自测
/// 录入接口 `add_self_measurement_to`,不是文档导入**。换句话说:同一组临床
/// 数据,产品已经确认「值得进趋势图」,也已经打通了「App 内手输」这一条路;
/// 「拍下等价的纸质/PDF 日记导入」这条同样会真实发生的路径,还没有被接到
/// 任何地方——这条测试量化的正是这第二条路径,不是在说这份数据本身没人管。
#[test]
fn home_monitoring_diary_yields_zero_trend_points() {
    let raw = corpus();
    let diary_index = raw
        .iter()
        .position(|(name, _)| name == "2026-04-30_血压记录_家庭监测")
        .expect("home monitoring diary fixture present");
    let docs = source_docs(&raw);
    assert_eq!(
        docs[diary_index].doc_type.as_deref(),
        Some("other"),
        "分类变了——如果这份日记现在被判成别的类型,下面「0 个趋势点」的结论\
         需要重新核实,不能直接沿用"
    );

    let agg = aggregate(&docs);
    let points_from_diary: usize = agg
        .labs
        .iter()
        .flat_map(|s| &s.points)
        .filter(|p| p.source == diary_index)
        .count();
    assert_eq!(
        points_from_diary, 0,
        "已知产品缺口:9 次血压 + 9 次心率 + 9 次血糖,一个趋势点都没有从这份\
         文档产出——如果这个数字变化了,说明有人开始处理这类文档,请更新上面\
         的模块级文档说明"
    );
}
