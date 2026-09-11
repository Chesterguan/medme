//! schema v1(spec §3)+ 逐字校验(spec §4)。
use crate::DeidError;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct LabItem {
    #[serde(default)] pub name: String,
    #[serde(default)] pub value: String,
    #[serde(default)] pub unit: String,
    #[serde(default)] pub ref_low: String,
    #[serde(default)] pub ref_high: String,
    #[serde(default)] pub flag: String,
    #[serde(default)] pub unverified: bool,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct MedItem {
    #[serde(default)] pub name: String,
    #[serde(default)] pub dose: String,
    #[serde(default)] pub freq: String,
    #[serde(default)] pub route: String,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct DiagnosisItem {
    #[serde(default)] pub text: String,
    #[serde(default)] pub icd: String,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct Extraction {
    #[serde(default)] pub doc_type: String,
    #[serde(default)] pub doc_date: String,
    #[serde(default)] pub labs: Vec<LabItem>,
    #[serde(default)] pub meds: Vec<MedItem>,
    #[serde(default)] pub diagnoses: Vec<DiagnosisItem>,
    #[serde(default)] pub impression: String,
    #[serde(default)] pub notes: String,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mode { Text, Image }

pub struct Verified { pub extraction: Extraction, pub rejected: usize, pub unverified: usize }

/// LLM 偶尔包 ```json 围栏;剥掉再解析。其它形状的错误如实返回。
pub fn parse_extraction(llm_json: &str) -> Result<Extraction, DeidError> {
    let s = llm_json.trim();
    let s = s.strip_prefix("```json").or_else(|| s.strip_prefix("```")).unwrap_or(s);
    let s = s.strip_suffix("```").unwrap_or(s).trim();
    Ok(serde_json::from_str(s)?)
}

fn norm_num(s: &str) -> String { s.replace(',', ".").split_whitespace().collect() }
fn norm_txt(s: &str) -> String { s.split_whitespace().collect() }

/// 文本档:逐字子串;图片档:数值 `,`→`.`、去空白后子串。空字段不查。
fn field_ok(value: &str, src: &str, src_norm: &str, mode: Mode, numeric: bool) -> bool {
    if value.is_empty() { return true; }
    match mode {
        Mode::Text => src.contains(value),
        Mode::Image => {
            let v = if numeric { norm_num(value) } else { norm_txt(value) };
            src_norm.contains(&v)
        }
    }
}

pub fn verify(mut e: Extraction, source_text: &str, mode: Mode) -> Verified {
    let src_norm = norm_num(source_text);
    let (mut rejected, mut unverified) = (0usize, 0usize);
    let mut keep = |ok: bool, flag: &mut bool| -> bool {
        match (mode, ok) {
            (_, true) => true,
            (Mode::Text, false) => { rejected += 1; false }
            (Mode::Image, false) => { *flag = true; unverified += 1; true }
        }
    };
    e.labs.retain_mut(|l| {
        let ok = field_ok(&l.name, source_text, &src_norm, mode, false)
            && field_ok(&l.value, source_text, &src_norm, mode, true)
            && field_ok(&l.unit, source_text, &src_norm, mode, false)
            && field_ok(&l.ref_low, source_text, &src_norm, mode, true)
            && field_ok(&l.ref_high, source_text, &src_norm, mode, true);
        keep(ok, &mut l.unverified)
    });
    let mut dummy = false;
    e.meds.retain(|m| keep(field_ok(&m.name, source_text, &src_norm, mode, false), &mut dummy));
    e.diagnoses.retain(|d| keep(field_ok(&d.text, source_text, &src_norm, mode, false), &mut dummy));
    Verified { extraction: e, rejected, unverified }
}

#[cfg(test)]
mod tests {
    use super::*;
    const SRC: &str = "白细胞计数 WBC 5.6 10^9/L 4.0-10.0\n血红蛋白 HGB 13,5 g/L 115-150\n诊断:2型糖尿病 E11.9";

    fn e() -> Extraction {
        Extraction {
            labs: vec![
                LabItem { name: "白细胞计数".into(), value: "5.6".into(), unit: "10^9/L".into(), ref_low: "4.0".into(), ref_high: "10.0".into(), ..Default::default() },
                LabItem { name: "血红蛋白".into(), value: "13.5".into(), unit: "g/L".into(), ref_low: "115".into(), ref_high: "150".into(), ..Default::default() },
                LabItem { name: "血小板".into(), value: "250".into(), ..Default::default() },
            ],
            diagnoses: vec![DiagnosisItem { text: "2型糖尿病".into(), icd: "E11.9".into() }],
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
        assert!(matches!(parse_extraction("not json"), Err(DeidError::Json(_))));
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
}
