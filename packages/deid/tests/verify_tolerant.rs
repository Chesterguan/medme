//! 图片档容错校验(Task 9b)的规则表,一条规则一对用例:**通过一个、不通过一个**。
//!
//! 背景:图片档里模型看的是原件,本地 OCR 文本只是旁证。逐字子串校验把 35.8% 的
//! 化验行判成「待核」,而这批行单独对真值看 95.6% 是对的 —— 错的是旁证,不是模型。
//! 这份 fixture 钉住「哪些差异算同一个字符串」以及**同样重要的**「哪些不算」:
//! 数值一律要求解析后**相等**,不许"接近";名字放宽到编辑距离 1,但两边都能被
//! 词典解析成**不同**术语时立刻收回(红细胞/白细胞恰好差一个字)。
//!
//! 文本档不受本轮影响:同一批输入在 `Mode::Text` 下仍然逐字,对不上就丢。

use deid::{verify, DiagnosisItem, Extraction, LabItem, MedItem, Mode};

/// 只有一条化验的抽取结果,按字段填。
fn lab(l: LabItem) -> Extraction {
    Extraction {
        labs: vec![l],
        ..Default::default()
    }
}

/// 图片档:这条化验过了校验吗(没被打「待核」)?
fn lab_ok(e: Extraction, src: &str) -> bool {
    let v = verify(e, src, Mode::Image);
    assert_eq!(v.extraction.labs.len(), 1, "图片档从不丢条目,只打标");
    !v.extraction.labs[0].unverified
}

/// 只填被测字段,其余留空(空字段一律算通过),这样断言指向的就是这一条规则。
fn value(v: &str) -> Extraction {
    lab(LabItem {
        value: v.into(),
        ..Default::default()
    })
}

fn unit(u: &str) -> Extraction {
    lab(LabItem {
        unit: u.into(),
        ..Default::default()
    })
}

fn name(n: &str) -> Extraction {
    lab(LabItem {
        name: n.into(),
        ..Default::default()
    })
}

// ---------- 规则 1:全角 / 半角 ----------

#[test]
fn fullwidth_digits_match_halfwidth_source() {
    assert!(lab_ok(value("５.６"), "白细胞计数 5.6 10^9/L"));
    assert!(lab_ok(unit("１０^９/Ｌ"), "白细胞计数 5.6 10^9/L"));
}

#[test]
fn fullwidth_does_not_excuse_a_different_digit() {
    assert!(!lab_ok(value("５.７"), "白细胞计数 5.6 10^9/L"));
}

// ---------- 规则 2:空白 ----------

#[test]
fn spaces_inside_the_model_value_are_ignored() {
    assert!(lab_ok(value("5. 6"), "白细胞计数 5.6 10^9/L"));
}

/// 反向**不许**:原文里被空白分开的两个数字不能拼成一个更长的数字来"验真"。
/// 去空白比对最早就是栽在这上面(verify.rs `comma_between_digits_to_dot` 的注释)。
#[test]
fn two_numbers_separated_by_space_do_not_fuse_into_one() {
    assert!(!lab_ok(value("115150"), "血红蛋白 HGB 135 g/L 115 150"));
}

// ---------- 规则 3:大小写 ----------

#[test]
fn unit_case_is_ignored() {
    assert!(lab_ok(unit("MMOL/L"), "血糖 GLU 6.1 mmol/L"));
}

#[test]
fn case_folding_does_not_excuse_a_different_unit() {
    assert!(!lab_ok(unit("MMOL/MOL"), "血糖 GLU 6.1 mmol/L"));
}

// ---------- 规则 4:常见 OCR 混淆(0/O、1/l/I/|、5/S、8/B) ----------

#[test]
fn ocr_confusable_letters_and_digits_are_one_class() {
    assert!(lab_ok(unit("1O^9/L"), "白细胞计数 5.6 10^9/L")); // 字母 O ↔ 数字 0
    assert!(lab_ok(value("S.6"), "白细胞计数 5.6 10^9/L")); // S ↔ 5
    assert!(lab_ok(value("8.6"), "白细胞计数 B.6 10^9/L")); // B ↔ 8
    assert!(lab_ok(value("1.6"), "白细胞计数 l.6 10^9/L")); // l ↔ 1
}

#[test]
fn confusion_classes_do_not_bleed_into_unrelated_digits() {
    assert!(!lab_ok(value("9.6"), "白细胞计数 5.6 10^9/L"));
    // 纯字母串不含任何数字,不许被折成数字来凑(SOS ≠ 505)
    assert!(!lab_ok(value("505"), "备注 SOS"));
}

// ---------- 规则 5:小数点 . 与 , ----------

#[test]
fn comma_decimal_matches_dot_decimal() {
    let e = lab(LabItem {
        name: "血糖".into(),
        ref_low: "3.9".into(),
        ref_high: "6.1".into(),
        ..Default::default()
    });
    assert!(lab_ok(e, "血糖 GLU 6,1 mmol/L 3,9-6,1"));
}

#[test]
fn comma_normalization_does_not_excuse_a_different_bound() {
    let e = lab(LabItem {
        name: "血糖".into(),
        ref_low: "3.8".into(),
        ..Default::default()
    });
    assert!(!lab_ok(e, "血糖 GLU 6,1 mmol/L 3,9-6,1"));
}

// ---------- 规则 6:负号 - 与 —(以及 – / −) ----------

#[test]
fn dash_variants_are_one_class() {
    let e = Extraction {
        doc_date: "2024—01—02".into(),
        ..Default::default()
    };
    let v = verify(e, "报告日期 2024-01-02", Mode::Image);
    assert!(v.unverified_fields.is_empty(), "破折号变体应视为同一个字符");
}

#[test]
fn dash_folding_does_not_excuse_a_different_date() {
    let e = Extraction {
        doc_date: "2024—01—03".into(),
        ..Default::default()
    };
    let v = verify(e, "报告日期 2024-01-02", Mode::Image);
    assert_eq!(v.unverified_fields, vec!["doc_date".to_string()]);
}

// ---------- 规则 7:× 与 x ----------

#[test]
fn times_sign_matches_letter_x() {
    assert!(lab_ok(unit("10×9/L"), "白细胞计数 5.6 10x9/L"));
}

#[test]
fn times_sign_folding_does_not_excuse_a_different_exponent() {
    assert!(!lab_ok(unit("10×6/L"), "白细胞计数 5.6 10x9/L"));
}

// ---------- 规则 8:↑↓ 与 H/L ----------

#[test]
fn arrow_flag_matches_letter_flag() {
    let up = lab(LabItem {
        name: "白细胞计数".into(),
        flag: "↑".into(),
        ..Default::default()
    });
    assert!(lab_ok(up, "白细胞计数 11.8 10^9/L H"));
    let down = lab(LabItem {
        name: "血红蛋白".into(),
        flag: "↓".into(),
        ..Default::default()
    });
    assert!(lab_ok(down, "血红蛋白 98 g/L L"));
}

/// **红线**:标志位只跟原文里独立成词、长度 ≤2 的词比。整行折叠着比的话
/// `HGB` 就够"验真"一个凭空的 ↑,而下游对字面 H/L 是优先采信的。
#[test]
fn a_flag_is_not_verified_by_a_letter_inside_a_longer_token() {
    let up = lab(LabItem {
        name: "血红蛋白".into(),
        flag: "↑".into(),
        ..Default::default()
    });
    assert!(!lab_ok(up, "血红蛋白 HGB 130 g/L 115-150"));
    // ↓ 同理:全文那些 `1`(10^9/L、11.8)不许把一个低值标志验真
    let down = lab(LabItem {
        name: "白细胞计数".into(),
        flag: "↓".into(),
        ..Default::default()
    });
    assert!(!lab_ok(down, "白细胞计数 11.8 10^9/L 4.0-10.0"));
}

#[test]
fn up_arrow_does_not_match_a_low_flag() {
    let up = lab(LabItem {
        name: "血红蛋白".into(),
        flag: "↑".into(),
        ..Default::default()
    });
    assert!(!lab_ok(up, "血红蛋白 98 g/L L"));
}

// ---------- 规则 9:数值解析后相等 ----------

#[test]
fn numeric_equality_ignores_trailing_zero_leading_dot_and_plus() {
    assert!(lab_ok(value("0.60"), "尿酸 0.6 mmol/L"));
    assert!(lab_ok(value(".6"), "尿酸 0.6 mmol/L"));
    assert!(lab_ok(value("+5.6"), "白细胞计数 5.6 10^9/L"));
}

/// **红线**:数值只认相等,永远不许"接近"放行。
#[test]
fn numeric_closeness_never_passes() {
    assert!(!lab_ok(value("5.61"), "白细胞计数 5.6 10^9/L"));
    assert!(!lab_ok(value("5.7"), "白细胞计数 5.6 10^9/L"));
    assert!(!lab_ok(value("56"), "白细胞计数 5.6 10^9/L"));
}

/// **红线**:数值判定没有锚点就会被"包含"下来 —— `1.5` ⊂ `11.5`。
/// 解析得出数的字段只跟切好词的原文数字比,不跟全文子串比。
#[test]
fn a_shorter_number_is_not_verified_by_a_longer_one() {
    assert!(!lab_ok(value("1.5"), "血糖 GLU 11.5 mmol/L"));
    assert!(lab_ok(value("11.5"), "血糖 GLU 11.5 mmol/L"));
    // 参考区间同理:0.11 不许被 10.115 收下
    let e = lab(LabItem {
        ref_low: "0.11".into(),
        ..Default::default()
    });
    assert!(!lab_ok(e, "某项 5.0 10.115-20.0"));
}

// ---------- 规则 9b:单位要落在词边界上 ----------

#[test]
fn unit_matches_when_neither_side_is_a_letter() {
    assert!(lab_ok(unit("g/L"), "血红蛋白 HGB 130 g/L 115-150")); // 整词
    assert!(lab_ok(unit("g/L"), "血红蛋白 HGB 130g/L 115-150")); // 紧跟数字
    assert!(lab_ok(unit("10^9/L"), "白细胞计数 5.6 ×10^9/L")); // 符号前缀不算边界
    assert!(lab_ok(unit("um/s"), "线速度VCL 54.6 (um/s)")); // 括号同理
}

/// **红线**:`g/L` 不许从 `mg/L` 里抠出来 —— 那是 1000 倍之差。
/// 量级前缀一律是字母,所以「左边不是字母」这一条正好盖住整类。
#[test]
fn unit_is_not_verified_by_a_longer_unit_whose_prefix_is_a_letter() {
    assert!(!lab_ok(unit("g/L"), "血红蛋白 HGB 130 mg/L 115-150"));
    assert!(!lab_ok(unit("mol/L"), "血糖 GLU 6.1 mmol/L"));
    assert!(!lab_ok(unit("IU/L"), "促甲状腺素 1.18 mIU/L"));
    assert!(!lab_ok(unit("g/L"), "血清铁 8.54 μg/L")); // 希腊字母 μ 也是字母
}

/// 文本档同样中招过,所以词边界这条**两档都管**(收紧,不是放宽)。
#[test]
fn text_mode_unit_also_needs_a_token_boundary() {
    let v = verify(unit("g/L"), "血红蛋白 HGB 130 mg/L 115-150", Mode::Text);
    assert_eq!(v.extraction.labs.len(), 0);
    assert_eq!(v.rejected, 1);
    let v = verify(unit("mg/L"), "血红蛋白 HGB 130 mg/L 115-150", Mode::Text);
    assert_eq!(v.extraction.labs.len(), 1);
    assert_eq!(v.rejected, 0);
}

// ---------- 规则 10:名字 —— 归一化后编辑距离 ≤ 1 ----------

#[test]
fn name_within_one_edit_of_the_source_passes() {
    // OCR 把「胞」认成「跑」:同一个词的误读,原文那一段不是任何别的术语
    assert!(lab_ok(name("白细胞计数"), "白细跑计数 5.6 10^9/L"));
}

#[test]
fn name_two_edits_away_stays_flagged() {
    assert!(!lab_ok(name("白细胞计数"), "白跑讣计数 5.6 10^9/L"));
}

/// 距离 1 但**两边都是词典里的真术语**(红细胞 / 白细胞正好差一个字)——
/// 这不是误读,是另一个指标,必须收回放行。
#[test]
fn name_one_edit_away_but_a_different_real_term_stays_flagged() {
    assert!(!lab_ok(name("红细胞计数"), "白细胞计数 5.6 10^9/L"));
}

/// 距离 1、**两边都不在词典里**,但差的那一个字各自是不同的术语(钾 / 钠)——
/// 词典外的名字正是风险最高的那批,护栏不能在那里失效。
#[test]
fn name_one_edit_away_stays_flagged_when_the_differing_char_is_another_term() {
    assert!(!lab_ok(name("血清钾测定"), "血清钠测定 4.5 mmol/L"));
    assert!(!lab_ok(name("尿钠浓度测定"), "尿钾浓度测定 30 mmol/L"));
}

/// 同上,但差的是一对对立修饰字(左 / 右):词典查不到,换一个就是另一处。
#[test]
fn name_one_edit_away_stays_flagged_for_opposite_modifier_chars() {
    assert!(!lab_ok(name("左侧肾上腺"), "右侧肾上腺 未见异常"));
}

/// 收紧只针对**替换**:OCR 断字多识/漏识一个字(插入/删除)照旧算误读。
#[test]
fn an_inserted_or_deleted_char_is_still_a_misread() {
    assert!(lab_ok(name("血清钾测定"), "血清钾测测定 4.5 mmol/L"));
}

/// 三字及以下不做模糊(钾/钠/氯之类,字太少分不开误读与邻项)。
#[test]
fn short_names_never_go_fuzzy() {
    assert!(!lab_ok(name("血钾"), "血钠 140 mmol/L"));
}

// ---------- 规则 11:名字 —— 词典解析到同一个术语 ----------

#[test]
fn name_resolving_to_the_same_term_as_the_source_passes() {
    // 模型输出规范名,原文印的是缩写:编辑距离很远,但是同一个指标
    assert!(lab_ok(name("白细胞计数"), "WBC 5.6 10^9/L"));
}

#[test]
fn name_resolving_to_a_different_term_stays_flagged() {
    assert!(!lab_ok(name("血小板计数"), "WBC 5.6 10^9/L"));
}

// ---------- 药品名走同一条名字规则 ----------

#[test]
fn med_name_uses_the_same_name_rule() {
    let e = Extraction {
        meds: vec![MedItem {
            name: "阿司匹林肠溶片".into(),
            ..Default::default()
        }],
        ..Default::default()
    };
    let v = verify(e, "阿司匹休肠溶片 100mg 每日一次", Mode::Image);
    assert!(!v.extraction.meds[0].unverified);
}

// ---------- 诊断走文本规则(折叠,但不模糊) ----------

#[test]
fn diagnosis_text_folds_but_does_not_go_fuzzy() {
    let ok = Extraction {
        diagnoses: vec![DiagnosisItem {
            text: "2 型糖尿病".into(),
            ..Default::default()
        }],
        ..Default::default()
    };
    assert!(
        !verify(ok, "诊断:2型糖尿病 E11.9", Mode::Image)
            .extraction
            .diagnoses[0]
            .unverified
    );
    let bad = Extraction {
        diagnoses: vec![DiagnosisItem {
            text: "1型糖尿病".into(),
            ..Default::default()
        }],
        ..Default::default()
    };
    assert!(
        verify(bad, "诊断:2型糖尿病 E11.9", Mode::Image)
            .extraction
            .diagnoses[0]
            .unverified
    );
}

// ---------- 文本档:一条都没放宽 ----------

#[test]
fn text_mode_stays_verbatim_for_every_tolerant_case() {
    for (e, src) in [
        (value("５.６"), "白细胞计数 5.6 10^9/L"),
        (value("5. 6"), "白细胞计数 5.6 10^9/L"),
        (unit("MMOL/L"), "血糖 GLU 6.1 mmol/L"),
        (unit("1O^9/L"), "白细胞计数 5.6 10^9/L"),
        (value("0.60"), "尿酸 0.6 mmol/L"),
        (name("白细胞计数"), "白细跑计数 5.6 10^9/L"),
        (name("白细胞计数"), "WBC 5.6 10^9/L"),
    ] {
        let v = verify(e, src, Mode::Text);
        assert_eq!(v.extraction.labs.len(), 0, "文本档仍逐字:{src}");
        assert_eq!(v.rejected, 1);
    }
}
