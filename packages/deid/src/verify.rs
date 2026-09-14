//! schema v1(spec §3)+ 逐字校验(spec §4)。
//! spec 硬规矩「字段全是原文逐字」适用于 schema v1 的每一个字符串字段,不止 labs 的五个——
//! doc_date/impression/notes、LabItem.flag、MedItem.dose/freq/route、DiagnosisItem.icd 同样要查(2026-09-11 修订轮 1)。
use crate::DeidError;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct LabItem {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub unit: String,
    #[serde(default)]
    pub ref_low: String,
    #[serde(default)]
    pub ref_high: String,
    #[serde(default)]
    pub flag: String,
    #[serde(default)]
    pub unverified: bool,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct MedItem {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub dose: String,
    #[serde(default)]
    pub freq: String,
    #[serde(default)]
    pub route: String,
    #[serde(default)]
    pub unverified: bool,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct DiagnosisItem {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub icd: String,
    #[serde(default)]
    pub unverified: bool,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct Extraction {
    #[serde(default)]
    pub doc_type: String,
    #[serde(default)]
    pub doc_date: String,
    #[serde(default)]
    pub labs: Vec<LabItem>,
    #[serde(default)]
    pub meds: Vec<MedItem>,
    #[serde(default)]
    pub diagnoses: Vec<DiagnosisItem>,
    #[serde(default)]
    pub impression: String,
    #[serde(default)]
    pub notes: String,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mode {
    Text,
    Image,
}

pub struct Verified {
    pub extraction: Extraction,
    pub rejected: usize,
    pub unverified: usize,
    pub unverified_fields: Vec<String>,
}

/// LLM 偶尔包 ```json 围栏;剥掉再解析。其它形状的错误如实返回。
pub fn parse_extraction(llm_json: &str) -> Result<Extraction, DeidError> {
    let s = llm_json.trim();
    let s = s
        .strip_prefix("```json")
        .or_else(|| s.strip_prefix("```"))
        .unwrap_or(s);
    let s = s.strip_suffix("```").unwrap_or(s).trim();
    Ok(serde_json::from_str(s)?)
}

/// 字段属于数值(化验的 value/ref_low/ref_high)还是文本(其余所有字段)。
/// 图片档下两者归一方式不同——数值只许 `,`→`.`,文本才许去空白(spec 修订轮 1)。
#[derive(Clone, Copy)]
enum FieldKind {
    Numeric,
    Text,
}

/// 只把"数字,数字"里的逗号变句号(两侧都得是数字才转),不整体去空白。
/// 若整体去空白,跨行相邻的两个数字会被拼接成一个更长的假数字,图片档就可能对着拼接结果误判为"验真"。
fn comma_between_digits_to_dot(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    for (i, &c) in chars.iter().enumerate() {
        let prev_digit = i > 0 && chars[i - 1].is_ascii_digit();
        let next_digit = i + 1 < chars.len() && chars[i + 1].is_ascii_digit();
        out.push(if c == ',' && prev_digit && next_digit {
            '.'
        } else {
            c
        });
    }
    out
}

/// 去掉所有空白;只用于文本字段的图片档比对——文本字段跨行拼接不构成"假验真"风险。
fn strip_ws(s: &str) -> String {
    s.split_whitespace().collect()
}

/// 文本档:逐字子串,对所有字段一视同仁。
/// 图片档:数值字段只做 `,`→`.` 归一(不去空白,防跨行数字拼接误判);文本字段允许去空白后比对。
/// 空字段视为通过——LLM 没提取到不算错。
fn field_ok(
    value: &str,
    src: &str,
    src_num: &str,
    src_ws: &str,
    mode: Mode,
    kind: FieldKind,
) -> bool {
    if value.is_empty() {
        return true;
    }
    match mode {
        Mode::Text => src.contains(value),
        Mode::Image => match kind {
            FieldKind::Numeric => src_num.contains(&comma_between_digits_to_dot(value)),
            FieldKind::Text => src_ws.contains(&strip_ws(value)),
        },
    }
}

/// 顶层标量字段(doc_date/impression/notes)校验:文本档不verbatim就清空并计入 rejected;
/// 图片档保留原值,把字段名记进 unverified_fields 并计入 unverified。
fn check_top_field(
    name: &'static str,
    field: &mut String,
    ok: bool,
    mode: Mode,
    rejected: &mut usize,
    unverified: &mut usize,
    unverified_fields: &mut Vec<String>,
) {
    if ok {
        return;
    }
    match mode {
        Mode::Text => {
            field.clear();
            *rejected += 1;
        }
        Mode::Image => {
            unverified_fields.push(name.to_string());
            *unverified += 1;
        }
    }
}

pub fn verify(mut e: Extraction, source_text: &str, mode: Mode) -> Verified {
    let src_num = comma_between_digits_to_dot(source_text);
    let src_ws = strip_ws(source_text);
    let (mut rejected, mut unverified) = (0usize, 0usize);
    let mut unverified_fields = Vec::new();

    let ok = field_ok(
        &e.doc_date,
        source_text,
        &src_num,
        &src_ws,
        mode,
        FieldKind::Text,
    );
    check_top_field(
        "doc_date",
        &mut e.doc_date,
        ok,
        mode,
        &mut rejected,
        &mut unverified,
        &mut unverified_fields,
    );
    let ok = field_ok(
        &e.impression,
        source_text,
        &src_num,
        &src_ws,
        mode,
        FieldKind::Text,
    );
    check_top_field(
        "impression",
        &mut e.impression,
        ok,
        mode,
        &mut rejected,
        &mut unverified,
        &mut unverified_fields,
    );
    let ok = field_ok(
        &e.notes,
        source_text,
        &src_num,
        &src_ws,
        mode,
        FieldKind::Text,
    );
    check_top_field(
        "notes",
        &mut e.notes,
        ok,
        mode,
        &mut rejected,
        &mut unverified,
        &mut unverified_fields,
    );

    let mut keep = |ok: bool, flag: &mut bool| -> bool {
        match (mode, ok) {
            (_, true) => true,
            (Mode::Text, false) => {
                rejected += 1;
                false
            }
            (Mode::Image, false) => {
                *flag = true;
                unverified += 1;
                true
            }
        }
    };
    e.labs.retain_mut(|l| {
        let ok = field_ok(
            &l.name,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Text,
        ) && field_ok(
            &l.value,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Numeric,
        ) && field_ok(
            &l.unit,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Text,
        ) && field_ok(
            &l.ref_low,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Numeric,
        ) && field_ok(
            &l.ref_high,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Numeric,
        ) && field_ok(
            &l.flag,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Text,
        );
        keep(ok, &mut l.unverified)
    });
    e.meds.retain_mut(|m| {
        let ok = field_ok(
            &m.name,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Text,
        ) && field_ok(
            &m.dose,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Text,
        ) && field_ok(
            &m.freq,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Text,
        ) && field_ok(
            &m.route,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Text,
        );
        keep(ok, &mut m.unverified)
    });
    e.diagnoses.retain_mut(|d| {
        let ok = field_ok(
            &d.text,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Text,
        ) && field_ok(
            &d.icd,
            source_text,
            &src_num,
            &src_ws,
            mode,
            FieldKind::Text,
        );
        keep(ok, &mut d.unverified)
    });

    Verified {
        extraction: e,
        rejected,
        unverified,
        unverified_fields,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const SRC: &str =
        "白细胞计数 WBC 5.6 10^9/L 4.0-10.0\n血红蛋白 HGB 13,5 g/L 115-150\n诊断:2型糖尿病 E11.9";

    fn e() -> Extraction {
        Extraction {
            labs: vec![
                LabItem {
                    name: "白细胞计数".into(),
                    value: "5.6".into(),
                    unit: "10^9/L".into(),
                    ref_low: "4.0".into(),
                    ref_high: "10.0".into(),
                    ..Default::default()
                },
                LabItem {
                    name: "血红蛋白".into(),
                    value: "13.5".into(),
                    unit: "g/L".into(),
                    ref_low: "115".into(),
                    ref_high: "150".into(),
                    ..Default::default()
                },
                LabItem {
                    name: "血小板".into(),
                    value: "250".into(),
                    ..Default::default()
                },
            ],
            diagnoses: vec![DiagnosisItem {
                text: "2型糖尿病".into(),
                icd: "E11.9".into(),
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    #[test]
    fn text_mode_drops_anything_not_verbatim() {
        let v = verify(e(), SRC, Mode::Text);
        // 13.5 原文是 13,5 → 文本档严格,丢;血小板不在原文,丢
        assert_eq!(v.extraction.labs.len(), 1);
        assert_eq!(v.rejected, 2);
        assert_eq!(v.unverified, 0);
        assert_eq!(v.extraction.diagnoses.len(), 1);
    }

    #[test]
    fn image_mode_keeps_but_flags() {
        let v = verify(e(), SRC, Mode::Image);
        assert_eq!(v.extraction.labs.len(), 3);
        assert!(!v.extraction.labs[0].unverified);
        assert!(!v.extraction.labs[1].unverified, "13,5 归一后等于 13.5");
        assert!(v.extraction.labs[2].unverified);
        assert_eq!(v.unverified, 1);
        assert_eq!(v.rejected, 0);
    }

    #[test]
    fn parse_tolerates_code_fence() {
        let j = "```json\n{\"doc_type\":\"lab\",\"labs\":[]}\n```";
        assert_eq!(parse_extraction(j).unwrap().doc_type, "lab");
    }

    #[test]
    fn parse_malformed_json_is_deid_error() {
        assert!(matches!(
            parse_extraction("not json"),
            Err(DeidError::Json(_))
        ));
    }

    #[test]
    fn empty_fields_are_allowed() {
        let ex = Extraction::default();
        let v = verify(ex, SRC, Mode::Text);
        assert_eq!(v.rejected, 0);
        assert_eq!(v.unverified, 0);
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let j = r#"{"doc_type":"lab","weird_extra_field":123,"labs":[]}"#;
        assert_eq!(parse_extraction(j).unwrap().doc_type, "lab");
    }

    // --- round 1 fixes: every string field must be verified, not just labs' five ---

    #[test]
    fn hallucinated_doc_date_is_dropped_in_text_mode() {
        let ex = Extraction {
            doc_date: "2099-01-01".into(),
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Text);
        assert_eq!(v.extraction.doc_date, "");
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn hallucinated_doc_date_is_flagged_in_image_mode() {
        let ex = Extraction {
            doc_date: "2099-01-01".into(),
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Image);
        assert_eq!(v.extraction.doc_date, "2099-01-01", "图片档保留原值");
        assert!(v.unverified_fields.contains(&"doc_date".to_string()));
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn hallucinated_impression_and_notes_are_dropped_in_text_mode() {
        let ex = Extraction {
            impression: "杜撰的印象".into(),
            notes: "杜撰的备注".into(),
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Text);
        assert_eq!(v.extraction.impression, "");
        assert_eq!(v.extraction.notes, "");
        assert_eq!(v.rejected, 2);
    }

    #[test]
    fn fabricated_lab_flag_drops_item_in_text_mode() {
        let ex = Extraction {
            labs: vec![LabItem {
                name: "白细胞计数".into(),
                value: "5.6".into(),
                unit: "10^9/L".into(),
                ref_low: "4.0".into(),
                ref_high: "10.0".into(),
                flag: "↑".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Text);
        assert_eq!(v.extraction.labs.len(), 0, "SRC 里没有 ↑,整条应丢");
        assert_eq!(v.rejected, 1);
    }

    const MED_SRC: &str = "阿司匹林肠溶片 100mg 每日一次 口服";

    #[test]
    fn med_with_hallucinated_dose_is_dropped_in_text_mode() {
        let ex = Extraction {
            meds: vec![MedItem {
                name: "阿司匹林肠溶片".into(),
                dose: "500mg".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, MED_SRC, Mode::Text);
        assert_eq!(v.extraction.meds.len(), 0);
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn med_with_hallucinated_dose_is_flagged_per_item_in_image_mode() {
        let ex = Extraction {
            meds: vec![MedItem {
                name: "阿司匹林肠溶片".into(),
                dose: "500mg".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, MED_SRC, Mode::Image);
        assert_eq!(v.extraction.meds.len(), 1);
        assert!(v.extraction.meds[0].unverified);
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn diagnosis_with_wrong_icd_is_dropped_in_text_mode() {
        let ex = Extraction {
            diagnoses: vec![DiagnosisItem {
                text: "2型糖尿病".into(),
                icd: "E11.0".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Text);
        assert_eq!(v.extraction.diagnoses.len(), 0, "SRC 里是 E11.9,不是 E11.0");
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn diagnosis_with_wrong_icd_is_flagged_in_image_mode() {
        let ex = Extraction {
            diagnoses: vec![DiagnosisItem {
                text: "2型糖尿病".into(),
                icd: "E11.0".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Image);
        assert_eq!(v.extraction.diagnoses.len(), 1);
        assert!(v.extraction.diagnoses[0].unverified);
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn image_mode_does_not_fuse_numbers_across_lines() {
        // line1 以 150 结尾,line2 紧接着以 160 开头;归一不许把跨行的两个数字接成 "150160"
        let src = "血红蛋白 HGB 13.5 g/L 115-150\n160 GLU 6.1 mmol/L 3.9-6.1";
        let ex = Extraction {
            labs: vec![LabItem {
                name: "血红蛋白".into(),
                value: "150160".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, src, Mode::Image);
        assert_eq!(v.extraction.labs.len(), 1);
        assert!(
            v.extraction.labs[0].unverified,
            "150 与 160 跨行相邻,不应拼接验真"
        );
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn image_mode_number_normalization_still_matches_comma_decimal() {
        let src = "血糖 GLU 7,1 mmol/L 3.9-6.1";
        let ex = Extraction {
            labs: vec![LabItem {
                name: "血糖".into(),
                value: "7.1".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, src, Mode::Image);
        assert!(!v.extraction.labs[0].unverified, "7,1 归一后应等于 7.1");
        assert_eq!(v.unverified, 0);
    }
}
