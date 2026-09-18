//! 每条活动度规则一个**阈值边界**用例:恰好在阈上、恰好在阈下各一次。
//! 数值全部来自 `.superpowers/sdd/disease-profile/sle-clinical-sources.md` §B.1/§B.2
//! 的 VERBATIM 行。
use chrono::NaiveDate;

mod common;
use common::{activity_pkg, lab_doc, ACTIVITY, TODAY};

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

fn enabled() -> Vec<parser::ProfileEvent> {
    vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }]
}

fn card(docs: &[parser::SourceDoc<'_>], pkg: &profile::Package) -> profile::Section {
    profile::materialize(docs, &enabled(), pkg, day(TODAY))
        .sections
        .into_iter()
        .find(|s| s.kind == "score_card")
        .expect("有化验就该有 score_card")
}

fn section_with(pkg: &profile::Package, docs: &[(&str, &str)]) -> profile::Section {
    let texts: Vec<String> = docs.iter().map(|(_, t)| t.to_string()).collect();
    let src: Vec<parser::SourceDoc> = docs
        .iter()
        .zip(&texts)
        .enumerate()
        .map(|(i, ((d, _), t))| parser::SourceDoc {
            index: i,
            date: Some(day(d)),
            text: t,
            doc_type: Some("lab_report".into()),
            title: None,
            extraction_json: None,
        })
        .collect();
    card(&src, pkg)
}

fn section(docs: &[(&str, &str)]) -> profile::Section {
    section_with(&activity_pkg(), docs)
}

fn score(docs: &[(&str, &str)]) -> serde_json::Value {
    section(docs).body
}

/// 同一份文档,带上云抽取结果(定性值只在这条路上看得见)。
fn score_extracted(extraction: &str, text: &str) -> serde_json::Value {
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day(TODAY)),
        text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: Some(extraction),
    }];
    card(&docs, &activity_pkg()).body
}

/// `hits` / `missed` / `unscored` 三个数组里的 id。
fn ids(body: &serde_json::Value, array: &str) -> Vec<String> {
    body[array]
        .as_array()
        .unwrap_or_else(|| panic!("body 里要有 {array} 数组"))
        .iter()
        .map(|h| h["id"].as_str().unwrap().into())
        .collect()
}

fn hit_ids(body: &serde_json::Value) -> Vec<String> {
    ids(body, "hits")
}

/// 某条描述符落进 `unscored` 时给出的理由。
fn reason(body: &serde_json::Value, id: &str) -> String {
    body["unscored"]
        .as_array()
        .unwrap()
        .iter()
        .find(|u| u["id"] == id)
        .unwrap_or_else(|| panic!("{id} 不在 unscored 里"))["reason"]
        .as_str()
        .unwrap()
        .to_string()
}

#[test]
fn leukopenia_boundary_is_strictly_below_three() {
    // VERBATIM:「< 3,000 white blood cells / x10⁹/L」→ 实现为 WBC < 3.0 ×10⁹/L。
    let b = score(&[(TODAY, &lab_doc("白细胞 2.9 10^9/L 3.5-9.5"))]);
    assert!(hit_ids(&b).contains(&"leukopenia".to_string()));
    assert_eq!(b["score"], 1);

    let b = score(&[(TODAY, &lab_doc("白细胞 3.0 10^9/L 3.5-9.5"))]);
    assert!(
        !hit_ids(&b).contains(&"leukopenia".to_string()),
        "恰好 3.0 不计分"
    );
}

#[test]
fn thrombocytopenia_boundary_is_strictly_below_one_hundred() {
    let b = score(&[(TODAY, &lab_doc("血小板 99 10^9/L 125-350"))]);
    assert_eq!(b["score"], 1);
    let b = score(&[(TODAY, &lab_doc("血小板 100 10^9/L 125-350"))]);
    assert_eq!(b["score"], 0);
}

#[test]
fn proteinuria_boundary_is_strictly_above_half_a_gram_per_day() {
    // VERBATIM:「>0.5 gram/24 hours」,权重 4。词典 canonical 是 mg/24h。
    let b = score(&[(TODAY, &lab_doc("24小时尿蛋白定量 0.51 g/24h"))]);
    assert_eq!(b["score"], 4);
    let b = score(&[(TODAY, &lab_doc("24小时尿蛋白定量 0.50 g/24h"))]);
    assert_eq!(b["score"], 0, "恰好 0.5 g/24h 不计分");
}

#[test]
fn upcr_never_scores_it_is_display_only() {
    // spec §5.2:UPCR 不能替代 24h 尿蛋白计分,只单独展示。同一张单子上 UPCR
    // 高得离谱、24h 定量却在阈下 —— 分数必须完全按 24h 那条走。
    // (单喂一份 UPCR 是空跑:那份文档什么都算不出,换成空文档一样过。)
    let b = score(&[(
        TODAY,
        &lab_doc("尿蛋白肌酐比 1200 mg/g\n24小时尿蛋白定量 0.3 g/24h"),
    )]);
    assert_eq!(b["score"], 0);
    assert!(!hit_ids(&b).contains(&"proteinuria".to_string()));
    assert!(
        ids(&b, "missed").contains(&"proteinuria".to_string()),
        "24h 那条是真比过了、没到阈 —— 是 ✘,不是未知"
    );
    assert!(!ids(&b, "unscored").contains(&"proteinuria".to_string()));
}

#[test]
fn the_proteinuria_threshold_stays_the_verbatim_half_gram_and_converts_to_a_mg_report() {
    // 包里写 §B.1 的原值「>0.5 gram/24 hours」;报告印 mg/24h 时由词典的换算表
    // (×1000)对齐 —— 不在包里先手算成 500,那样读包的人就看不出它不是源行原值。
    let pkg: serde_json::Value = serde_json::from_str(ACTIVITY).unwrap();
    let item = pkg["rules"]["activity"]["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["id"] == "proteinuria")
        .unwrap()
        .clone();
    assert_eq!(item["threshold"], 0.5);
    assert_eq!(item["threshold_unit"], "g/24h");

    let b = score(&[(TODAY, &lab_doc("24小时尿蛋白定量 510 mg/24h"))]);
    assert_eq!(b["score"], 4, "510 mg = 0.51 g,过阈");
    let b = score(&[(TODAY, &lab_doc("24小时尿蛋白定量 500 mg/24h"))]);
    assert_eq!(b["score"], 0, "500 mg 恰好 0.5 g,不计分");
}

#[test]
fn a_package_still_using_the_old_field_name_fails_loudly_instead_of_scoring() {
    // 阈值单位那个字段从 `canonical_unit` 改名成了 `threshold_unit`(旧名在骗包作者:
    // 它是**阈值自己写的单位**,不是规范单位;照字面写 `mg/24h` 而值仍是 0.5,阈值就
    // 静默变成 0.5 mg)。**刻意不留 serde 兼容**:拿旧名写的包在这里读不到单位,整条
    // 落「未知 + 理由」,而不是被默默当成另一个意思。
    let mut raw: serde_json::Value = serde_json::from_str(ACTIVITY).expect("夹具包必须解析");
    for item in raw["rules"]["activity"]["items"]
        .as_array_mut()
        .expect("items 是数组")
    {
        if let Some(u) = item
            .as_object_mut()
            .and_then(|o| o.remove("threshold_unit"))
        {
            item["canonical_unit"] = u;
        }
    }
    let pkg: profile::Package = serde_json::from_value(raw).expect("夹具包必须解析");
    let b = section_with(&pkg, &[(TODAY, &lab_doc("24小时尿蛋白定量 3.2 g/24h"))]).body;
    assert_eq!(b["score"], 0, "读不到阈值单位就不许计分");
    let reason = b["unscored"]
        .as_array()
        .expect("unscored 是数组")
        .iter()
        .find(|u| u["id"] == "proteinuria")
        .map(|u| u["reason"].clone())
        .expect("蛋白尿那条要如实说算不了");
    assert_eq!(reason, "这一条没写阈值的单位(threshold_unit),比不了");
}

#[test]
fn low_complement_uses_the_reports_own_lower_limit_not_a_fixed_number() {
    // VERBATIM:「below the lower limit of normal for testing laboratory」。
    // 同一个 0.85 g/L,在下限 0.9 的医院算低,在下限 0.8 的医院不算。
    let b = score(&[(TODAY, &lab_doc("补体C3 0.85 g/L 0.9-1.8"))]);
    assert_eq!(b["score"], 2);
    let b = score(&[(TODAY, &lab_doc("补体C3 0.85 g/L 0.8-1.8"))]);
    assert_eq!(b["score"], 0);
}

#[test]
fn low_complement_scores_only_once_even_when_c3_and_c4_are_both_low() {
    // 一条描述符 = 一次 2 分(CH50/C3/C4 是同一条 "Low complement")。
    let b = score(&[(
        TODAY,
        &lab_doc("补体C3 0.4 g/L 0.9-1.8\n补体C4 0.05 g/L 0.1-0.4"),
    )]);
    assert_eq!(b["score"], 2);
}

#[test]
fn a_result_older_than_the_window_does_not_score() {
    // VERBATIM:「present at the time of the visit or in the preceding 10 days」。
    let b = score(&[("2026-09-05", &lab_doc("白细胞 2.0 10^9/L 3.5-9.5"))]); // 11 天前
    assert_eq!(b["score"], 0);
    let b = score(&[("2026-09-06", &lab_doc("白细胞 2.0 10^9/L 3.5-9.5"))]); // 10 天前
    assert_eq!(b["score"], 1);
}

#[test]
fn casts_are_detected_from_the_report_text_not_from_a_number() {
    let b = score(&[(TODAY, &lab_doc("尿沉渣:可见红细胞管型"))]);
    assert!(hit_ids(&b).contains(&"casts".to_string()));
    assert_eq!(b["score"], 4);
}

#[test]
fn the_score_is_labelled_as_the_lab_computable_part_and_declares_a_max_of_eighteen() {
    let b = score(&[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8"))]);
    assert_eq!(b["max"], 18);
    assert_eq!(b["label"], "化验可算部分");
    assert_eq!(b["window_days"], 10);
    // 界面不许把它说成 SLEDAI 总分。
    let s = serde_json::to_string(&b).unwrap();
    assert!(!s.contains("SLEDAI 总分"));
}

#[test]
fn every_hit_carries_its_source_id_and_the_reports_it_used() {
    let b = score(&[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8"))]);
    let h = &b["hits"][0];
    assert_eq!(h["source"], "S1");
    assert_eq!(h["evidence"][0]["document_index"], 0);
    assert_eq!(h["evidence"][0]["analyte"], "complement_c3");
}

#[test]
fn a_qualitative_positive_dsdna_scores_but_is_flagged_as_a_deviation() {
    // §B.2:表格写的是 Farr 法;中国实验室多用 ELISA/CLIFT,定性「阳性」也计分,
    // 但必须标出偏差 —— 不标就是把一个方法学差异藏起来。
    let extraction = r#"{"labs":[{"name":"抗双链DNA抗体","value":"阳性","unit":"","ref_low":"","ref_high":"","flag":""}],"facts":[]}"#;
    let text = lab_doc("抗双链DNA抗体 阳性");
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day(TODAY)),
        text: &text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: Some(extraction),
    }];
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }];
    let v = profile::materialize(&docs, &events, &activity_pkg(), day(TODAY));
    let b = &v
        .sections
        .iter()
        .find(|s| s.kind == "score_card")
        .unwrap()
        .body;
    assert_eq!(b["score"], 2);
    assert!(b["hits"][0]["caveat"].as_str().unwrap().contains("Farr"));
}

#[test]
fn a_descriptor_with_nothing_to_read_is_listed_unscored_never_as_a_clean_miss() {
    // 「算过了、没达到」和「这次算不出来」是两回事:窗口里只有一张血常规时,
    // 补体那条既不是 ✔ 也不是 ✘,是未知 —— 混成 0 分就等于替医生说「补体正常」。
    let b = score(&[(TODAY, &lab_doc("白细胞 5.0 10^9/L 3.5-9.5"))]);
    let unscored: Vec<String> = b["unscored"]
        .as_array()
        .unwrap()
        .iter()
        .map(|u| u["id"].as_str().unwrap().into())
        .collect();
    assert_eq!(b["score"], 0);
    assert!(hit_ids(&b).is_empty());
    // 没做的:未知。
    assert!(unscored.contains(&"low_complement".to_string()));
    assert!(unscored.contains(&"thrombocytopenia".to_string()));
    // 做了、正常的:✘ —— 既不计分,也不叫未知。
    assert!(
        !unscored.contains(&"leukopenia".to_string()),
        "白细胞这次是真算过了"
    );
    for u in b["unscored"].as_array().unwrap() {
        assert!(
            !u["reason"].as_str().unwrap().is_empty(),
            "每条未知都要说清为什么算不出来"
        );
    }
}

// --- C1:管型那条按「行」判,否定不算命中 -----------------------------------

#[test]
fn a_negated_cast_line_never_scores() {
    // 中国尿沉渣报告逐项印「项目 + 结果」,「未见 / 阴性 / 0.00 / 0 个」都是
    // 「做了、没有」。在整份文档上裸 `contains` 会把这些判成命中 +4 —— 18 分制里
    // 最重的一档,而且与 §B.1 VERBATIM「Heme-granular or red blood cell casts.」
    // 的方向相反。
    for rows in [
        "红细胞管型 未见\n颗粒管型 阴性",
        "颗粒管型 0.00 /uL 0-0",
        "尿沉渣镜检:未见红细胞管型及颗粒管型",
        "红细胞管型 阴性",
        "红细胞管型 0.00 /uL 0-0",
        "红细胞管型 0 个/LP",
        "红细胞管型 未检出",
        "红细胞管型 (-)",
        "红细胞管型 （-）",
    ] {
        let b = score(&[(TODAY, &lab_doc(rows))]);
        assert_eq!(b["score"], 0, "{rows:?} 不该计分");
        assert!(!hit_ids(&b).contains(&"casts".to_string()), "{rows:?}");
    }
}

#[test]
fn a_negated_cast_line_lands_in_missed_carrying_that_line_verbatim() {
    // ✘ 要看得见:「尿沉渣写着未见红细胞管型」是医生能直接用的阴性结果,
    // 和「这张卡压根没提管型」必须长得不一样。
    let b = score(&[(TODAY, &lab_doc("尿沉渣镜检:未见红细胞管型"))]);
    assert!(!hit_ids(&b).contains(&"casts".to_string()));
    assert!(
        !ids(&b, "unscored").contains(&"casts".to_string()),
        "写着未见 = 这项做过了,不是未知"
    );
    let m = b["missed"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == "casts")
        .expect("✘ 要出现在 missed 里")
        .clone();
    assert_eq!(
        m["evidence"][0]["value"], "尿沉渣镜检:未见红细胞管型",
        "证据要带原文这一行,不是命中的那几个字 —— 否则证据链里看不出它被否定了"
    );
}

#[test]
fn a_positive_cast_line_in_the_same_report_still_scores() {
    // 同一份报告里一行阴性一行阳性:有阳性就是有。
    let b = score(&[(TODAY, &lab_doc("颗粒管型 未见\n尿沉渣:可见红细胞管型"))]);
    assert!(hit_ids(&b).contains(&"casts".to_string()));
    assert_eq!(b["score"], 4);
}

#[test]
fn granular_casts_alone_do_not_score_there_is_no_verbatim_chinese_wording() {
    // §B.1 写的是「**Heme**-granular or red blood cell casts.」。「颗粒管型」比它宽
    // (发热/脱水/剧烈运动后都可见),§A.3 的 VERBATIM 三串里也没有「血红蛋白管型」
    // —— 按 global-constraints 第 8 条,没有 VERBATIM 源行的写法不进包。
    let b = score(&[(TODAY, &lab_doc("颗粒管型 可见\n血红蛋白管型 可见"))]);
    assert_eq!(b["score"], 0);
    assert!(ids(&b, "unscored").contains(&"casts".to_string()));
}

// --- C2:空态只在真的没东西可看时出 ------------------------------------------

#[test]
fn a_report_the_engine_cannot_score_still_expands_and_never_claims_there_are_no_labs() {
    // 用户当天交了一张印着 `尿红细胞 8 /HPF`、`尿白细胞 12 /HPF` 的尿常规(两条都
    // 过 SLEDAI 的 >5)。引擎读不懂它,但绝不能显示成「你还没去抽血」。
    // 同时钉住裁决 (c):这两条必须落进 unscored,不许被当成「算过了、正常」。
    let s = section(&[(TODAY, &lab_doc("尿红细胞 8 /HPF 0-5\n尿白细胞 12 /HPF 0-5"))]);
    assert_eq!(s.body["score"], 0);
    let u = ids(&s.body, "unscored");
    assert!(u.contains(&"hematuria".to_string()), "unscored: {u:?}");
    assert!(u.contains(&"pyuria".to_string()), "unscored: {u:?}");
    assert!(hit_ids(&s.body).is_empty());
    assert!(
        s.empty_hint.is_none(),
        "当天有单子,不许说「最近 10 天还没有化验结果」"
    );
}

#[test]
fn with_nothing_in_the_window_at_all_the_card_folds() {
    let s = section_with(&activity_pkg(), &[]);
    assert!(s.empty_hint.is_some());
    assert_eq!(s.body["score"], 0);
}

// --- I2 / I3:dsDNA 的两个执行漏洞 ---------------------------------------------

#[test]
fn a_numeric_dsdna_without_a_printed_range_is_unknown_not_a_clean_miss() {
    // §A.3:anti-dsDNA 三个方法族、三种结果形态。ELISA 报 120 IU/mL 而没印上限时,
    // 高不高完全取决于这家实验室 —— 那是未知,不是「不高」。
    let extraction = r#"{"labs":[{"name":"抗双链DNA抗体","value":"120","unit":"IU/mL","ref_low":"","ref_high":"","flag":""}],"facts":[]}"#;
    let b = score_extracted(extraction, &lab_doc("抗双链DNA抗体 120 IU/mL"));
    assert_eq!(b["score"], 0);
    assert!(ids(&b, "unscored").contains(&"dsdna_high".to_string()));
    assert!(
        reason(&b, "dsdna_high").contains("参考区间"),
        "理由要说清是没印区间:{}",
        reason(&b, "dsdna_high")
    );
}

#[test]
fn a_fullwidth_plus_counts_as_positive_just_like_the_halfwidth_one() {
    // 中国报告单全角符号极常见;`terminology::normalize_term` 本来就折全角,
    // 这里不用它就会漏 2 分。
    for v in ["阳性", "强阳性", "++", "＋＋"] {
        let extraction = format!(
            r#"{{"labs":[{{"name":"抗双链DNA抗体","value":"{v}","unit":"","ref_low":"","ref_high":"","flag":""}}],"facts":[]}}"#
        );
        let b = score_extracted(&extraction, &lab_doc(&format!("抗双链DNA抗体 {v}")));
        assert_eq!(b["score"], 2, "{v} 应当按阳性计分");
    }
}

#[test]
fn a_qualitative_negative_dsdna_is_a_miss_not_an_unknown() {
    let extraction = r#"{"labs":[{"name":"抗双链DNA抗体","value":"阴性","unit":"","ref_low":"","ref_high":"","flag":""}],"facts":[]}"#;
    let b = score_extracted(extraction, &lab_doc("抗双链DNA抗体 阴性"));
    assert_eq!(b["score"], 0);
    assert!(ids(&b, "missed").contains(&"dsdna_high".to_string()));
    assert!(!ids(&b, "unscored").contains(&"dsdna_high".to_string()));
}

// --- I4:未知的理由要说对原因 --------------------------------------------------

#[test]
fn the_unknown_reason_says_not_done_when_the_item_is_simply_absent() {
    // 一张只有补体的单子,白细胞那条的理由不能是「单位换算不成 10*9/L」——
    // 单子上根本没有白细胞这一行,用户只会以为是自己哪里弄错了。
    let b = score(&[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8"))]);
    let r = reason(&b, "leukopenia");
    assert!(r.contains("没有做"), "理由说错了原因:{r}");
    assert!(!r.contains("单位"), "理由说错了原因:{r}");
}

// --- I7:包里的窗口写坏了不许让库 panic ----------------------------------------

#[test]
fn an_unusable_window_is_reported_invalid_instead_of_panicking() {
    // `today - Duration::days(n)` 在 n 大到越界时直接 panic,而 `window_days` 是包里
    // 的裸 i64、加载时不校验。在移动端这条路走 FFI,一次 panic 就是整个 App 崩。
    for bad in ["100000000", "-1", "0"] {
        let pkg: profile::Package = serde_json::from_str(
            &ACTIVITY.replace("\"window_days\":10", &format!("\"window_days\":{bad}")),
        )
        .expect("包要能解析");
        let s = section_with(&pkg, &[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8"))]);
        assert_eq!(s.body["score"], 0, "window_days={bad}");
        assert_eq!(
            s.body["unscored"].as_array().unwrap().len(),
            8,
            "window_days={bad}:八条全该是未知"
        );
        for u in s.body["unscored"].as_array().unwrap() {
            assert_eq!(u["reason"], "窗口设置无效", "window_days={bad}");
        }
        assert!(s.empty_hint.is_none(), "window_days={bad}:不是「还没抽血」");
    }
}

// --- M3 / M4:包写坏了要说出来,不许伪装成 ✘ ----------------------------------

#[test]
fn a_rule_kind_this_engine_does_not_know_is_reported_unknown_not_a_silent_zero() {
    let pkg: profile::Package = serde_json::from_str(
        &ACTIVITY.replace("\"kind\":\"flag_low\"", "\"kind\":\"某种更晚的规则\""),
    )
    .expect("包要能解析");
    let b = section_with(&pkg, &[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8"))]).body;
    assert!(ids(&b, "unscored").contains(&"low_complement".to_string()));
    assert!(reason(&b, "low_complement").contains("更新 App"));
}

#[test]
fn an_item_whose_weight_is_not_an_integer_is_unknown_not_a_zero_point_hit() {
    // 命中但不加分的条目在卡片上没有任何信号 —— 那是最难发现的一种错。
    let pkg: profile::Package = serde_json::from_str(&ACTIVITY.replace(
        "\"weight\":2,\"kind\":\"flag_low\"",
        "\"weight\":2.5,\"kind\":\"flag_low\"",
    ))
    .expect("包要能解析");
    let b = section_with(&pkg, &[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8"))]).body;
    assert_eq!(b["score"], 0);
    assert!(!hit_ids(&b).contains(&"low_complement".to_string()));
    assert!(reason(&b, "low_complement").contains("权重"));
}

// --- 窗口:没有日期的文档一分不给 ----------------------------------------------

#[test]
fn a_document_with_no_date_never_scores() {
    // 猜日期等于编分数 —— SLEDAI-2K 的 10 天窗口是表格原文的硬要求。
    let text = lab_doc("补体C3 0.4 g/L 0.9-1.8\n尿沉渣:可见红细胞管型");
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: None,
        text: &text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: None,
    }];
    let b = card(&docs, &activity_pkg()).body;
    assert_eq!(b["score"], 0);
    assert!(hit_ids(&b).is_empty());
}

// --- 证据逐字:给人看的永远是纸上那个数 ---------------------------------------

/// 某条描述符在 `hits`/`missed` 里的第一条证据。
fn evidence(body: &serde_json::Value, array: &str, id: &str) -> serde_json::Value {
    body[array]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == id)
        .unwrap_or_else(|| panic!("{id} 不在 {array} 里"))["evidence"][0]
        .clone()
}

#[test]
fn numeric_evidence_carries_what_the_report_printed_not_the_converted_number() {
    // 比是拿规范值比的(0.3 g = 300 mg,阈 500 mg),但证据链里必须还是「0.3 g/24h」
    // —— 医生要能在纸上原样找到它。规范套另放在名字自己说清楚的两个键下。
    let b = score(&[(TODAY, &lab_doc("24小时尿蛋白定量 0.3 g/24h"))]);
    let e = evidence(&b, "missed", "proteinuria");
    assert_eq!(e["value"], "0.3");
    assert_eq!(e["unit"], "g/24h");
    assert_eq!(e["value_canonical"], 300.0);
    assert_eq!(e["unit_canonical"], "mg/24h");
    assert_eq!(e["values_converted"], false);
}

#[test]
fn a_scoring_numeric_hit_carries_the_printed_pair_too() {
    let b = score(&[(TODAY, &lab_doc("24小时尿蛋白定量 0.51 g/24h"))]);
    let e = evidence(&b, "hits", "proteinuria");
    assert_eq!(e["value"], "0.51");
    assert_eq!(e["unit"], "g/24h");
    assert_eq!(e["value_canonical"], 510.0);
}

#[test]
fn flag_evidence_carries_the_printed_pair_and_the_canonical_one_separately() {
    // 齐鲁印 mg/L、别家印 g/L(§A.3 的 1000× 坑)。命中的是「800 mg/L」这张单子,
    // 证据就得是 800 mg/L。
    let b = score(&[(TODAY, &lab_doc("补体C3 800 mg/L 900-1800"))]);
    let e = evidence(&b, "hits", "low_complement");
    assert_eq!(e["value"], "800");
    assert_eq!(e["unit"], "mg/L");
    assert_eq!(e["value_canonical"], 0.8);
    assert_eq!(e["unit_canonical"], "g/L");
}

#[test]
fn a_series_whose_units_were_unified_says_so_on_every_piece_of_evidence() {
    // 两张单子一张印 g/L 一张印 mg/L,`parser` 会把整条序列统一到规范单位 ——
    // 此时 `value`/`unit` 在**纸上找不到**,必须由 `values_converted` 说出来,
    // 不说就等于改写原文(`parser::AnalyteSeries::values_converted` 的原话)。
    let b = score(&[
        ("2026-09-15", &lab_doc("补体C3 0.4 g/L 0.9-1.8")),
        (TODAY, &lab_doc("补体C3 500 mg/L 900-1800")),
    ]);
    let e = evidence(&b, "hits", "low_complement");
    assert_eq!(
        e["values_converted"], true,
        "混了印刷单位就必须承认这个数是换算过的:{e}"
    );
    assert_eq!(e["unit"], "g/L", "统一后的单位是词典规范单位");
}
