//! Structured payload encoding for manually-entered self-measurements ("记录").
//!
//! Manual entry has no OCR'd original — the "document" *is* the entry. Per the
//! DICOM/txt precedent (`pipeline::add_text_layer_document` / the DICOM-summary
//! path in `pipeline::lib::dicom_summary`), we synthesize a human-readable text
//! and store it exactly as if it were `ocr_result.text`. But unlike genuine OCR
//! text — which [`crate::extract_labs`] must read with necessarily-fuzzy regexes
//! because the printed layout is out of our control — this text is BOTH written
//! and read by our own code. So it carries an exact, versioned, machine-readable
//! payload alongside the human-readable prose, and [`crate::aggregate`] reads the
//! payload back verbatim rather than re-parsing the prose with `extract_labs`.
//!
//! See `MANUAL-ENTRY-DESIGN.md` §3.2/§3.3 for the accepted design this module
//! implements.

use serde::{Deserialize, Serialize};

/// Sentinel marking the start of the machine-readable payload line, with an
/// explicit version tag. A future format change bumps the version so a reader
/// running old code fails closed (`parse_self_measurement_payload` → `None`)
/// instead of silently misreading a newer shape.
pub const SELF_MEASUREMENT_MARKER: &str = "###MEDME-SELF-V1###";

/// One value from a self-measurement entry. A blood-pressure entry carries two
/// (systolic + diastolic) sharing one document/`measured_at` — see
/// `MANUAL-ENTRY-DESIGN.md` §5.3: one measurement is the smallest editable unit,
/// so BOTH values live in the same document and are edited/deleted together.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SelfMeasuredValue {
    /// Canonical analyte key from `terminology::dictionary_entries()` (e.g.
    /// `"bp_systolic"`) — never a raw display name. The five supported
    /// analytes (`bp_systolic`, `bp_diastolic`, `heart_rate`, `body_weight`,
    /// `body_temperature`, `glucose`) are already resolvable in the dictionary;
    /// the picker in the mobile UI only ever offers these keys.
    pub analyte_key: String,
    pub value: f64,
    /// Canonical unit for this analyte (e.g. `"mmHg"`) — the writer (mobile FFI)
    /// always sends the dictionary's canonical unit, so `aggregate()` never has
    /// to convert on read-back.
    pub unit: String,
}

#[derive(Serialize, Deserialize)]
struct Payload {
    values: Vec<SelfMeasuredValue>,
}

/// Synthesize `ocr_result.text` for a self-measurement document: caller-supplied
/// human-readable lines (what a person sees in the document viewer/timeline),
/// then a blank line, then the marker line carrying the exact structured
/// payload [`parse_self_measurement_payload`] reads back.
///
/// `human_lines` is entirely the caller's phrasing (e.g. `["血压 128/82
/// mmHg", "记录时间:2026-08-04 07:30"]`) — this module has no opinion on
/// wording, only on the structured tail that follows it.
pub fn render_self_measurement_text(
    human_lines: &[String],
    values: &[SelfMeasuredValue],
) -> String {
    let mut out = human_lines.join("\n");
    out.push_str("\n\n");
    out.push_str(SELF_MEASUREMENT_MARKER);
    out.push_str(
        &serde_json::to_string(&Payload {
            values: values.to_vec(),
        })
        .expect("Payload of plain String/f64 fields always serializes"),
    );
    out
}

/// Read the structured payload back out of a `doc_type == "self_measurement"`
/// document's text. `None` if the marker line is missing or the JSON after it
/// doesn't parse — the caller treats that as "no values" (the document itself
/// stays visible in the timeline/archive via its human-readable prose; it just
/// contributes nothing to trend aggregation). Never guesses a partial reading.
pub fn parse_self_measurement_payload(text: &str) -> Option<Vec<SelfMeasuredValue>> {
    let line = text
        .lines()
        .find(|l| l.starts_with(SELF_MEASUREMENT_MARKER))?;
    let json_str = line.strip_prefix(SELF_MEASUREMENT_MARKER)?;
    let payload: Payload = serde_json::from_str(json_str).ok()?;
    Some(payload.values)
}

/// A home (self-measured) reference range, with its clinical source cited —
/// same convention as `problem_map.json`'s `source` field on each mapped entry.
pub struct HomeRefRange {
    pub low: Option<f64>,
    pub high: Option<f64>,
    pub source: &'static str,
}

/// The home/self-measured reference range for `analyte_key`, or `None` when no
/// defensible home range exists. `None` is a real answer, not a gap to fill
/// later with a guess: the caller must show the bare value with **no** flag
/// rather than invent a threshold (`MANUAL-ENTRY-DESIGN.md` §3.3/§5.2 — "查不到
/// 出处就不给区间"). `body_weight` and `glucose` are deliberately always `None`
/// (see the per-arm comments); `body_temperature` is `None` for a narrower
/// reason: the number itself is textbook-common but this project could not
/// verify one specific guideline citation for it in this round (search quota
/// exhausted) — update the comment and add the arm back if a citation surfaces.
pub fn home_ref_range(analyte_key: &str) -> Option<HomeRefRange> {
    match analyte_key {
        "bp_systolic" => Some(HomeRefRange {
            low: None,
            high: Some(135.0),
            source: "中国高血压防治指南(2024年修订版):家庭自测血压正常上限 135/85 mmHg,\
                显著低于诊室血压诊断切点 140/90 mmHg —— 不可套用诊室区间。",
        }),
        "bp_diastolic" => Some(HomeRefRange {
            low: None,
            high: Some(85.0),
            source: "中国高血压防治指南(2024年修订版):家庭自测血压正常上限 135/85 mmHg,\
                显著低于诊室血压诊断切点 140/90 mmHg —— 不可套用诊室区间。",
        }),
        "heart_rate" => Some(HomeRefRange {
            low: Some(60.0),
            high: Some(100.0),
            source: "成年人静息心率正常范围 —— 内科学/生命体征通用共识,跨指南一致的基础\
                生理学常数,不是某一部中国专病指南的定值。",
        }),
        // 体温:数值本身教科书级通用(腋温 36.0-37.3°C,≥37.3 记为发热),但本次
        // 检索配额耗尽,未能核实到某一具体指南的原文页码 —— 按项目规矩"查不到
        // 出处就不给区间",裸值显示、不出 flag。若日后补上确切出处,在此加回,
        // 并注意仅适用于腋下测量法(口温/耳温/额温有系统性偏差,不做换算)。
        "body_temperature" => None,
        // 体重脱离身高/BMI 无法判断"正常与否",没有通用的高低切点 —— 宁可裸值
        // 显示,不编一个。
        "body_weight" => None,
        // 家测血糖为指尖毛细血管血,与化验单的静脉血浆血糖系统性存在差异(约
        // 10-15%,具体系数依设备而定);现有的"正常范围"要么是诊断切点(用于
        // 确诊糖尿病,不是"正常与否"的判断)要么是已确诊患者的个体化治疗目标
        // (因人而异),两者概念都不适用于"给一个通用正常区间"这件事。
        "glucose" => None,
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_a_single_value() {
        let values = vec![SelfMeasuredValue {
            analyte_key: "heart_rate".into(),
            value: 72.0,
            unit: "/min".into(),
        }];
        let text = render_self_measurement_text(&["心率 72 /min".to_string()], &values);
        assert!(text.starts_with("心率 72 /min"));
        assert!(text.contains(SELF_MEASUREMENT_MARKER));
        let parsed = parse_self_measurement_payload(&text).expect("payload parses");
        assert_eq!(parsed, values);
    }

    #[test]
    fn round_trips_two_values_sharing_one_document() {
        // 血压:收缩压+舒张压共享同一份文档(§5.3),因此共享同一段合成文本。
        let values = vec![
            SelfMeasuredValue {
                analyte_key: "bp_systolic".into(),
                value: 128.0,
                unit: "mmHg".into(),
            },
            SelfMeasuredValue {
                analyte_key: "bp_diastolic".into(),
                value: 82.0,
                unit: "mmHg".into(),
            },
        ];
        let text = render_self_measurement_text(
            &[
                "血压 128/82 mmHg".to_string(),
                "记录时间:2026-08-04 07:30".to_string(),
            ],
            &values,
        );
        let parsed = parse_self_measurement_payload(&text).expect("payload parses");
        assert_eq!(parsed, values);
    }

    #[test]
    fn missing_marker_returns_none_not_a_guess() {
        assert!(parse_self_measurement_payload("普通的一段病历文字,没有任何标记。").is_none());
    }

    #[test]
    fn malformed_json_after_marker_returns_none() {
        let text = format!("血压 128/82 mmHg\n\n{SELF_MEASUREMENT_MARKER}{{not valid json");
        assert!(
            parse_self_measurement_payload(&text).is_none(),
            "损坏的载荷必须读不出来,而不是半猜"
        );
    }

    #[test]
    fn future_format_version_is_not_recognized() {
        // 一个假想的 V2 标记:当前代码只认 V1,必须读不出来而不是误读成 V1 形状。
        let text = "血压 128/82 mmHg\n\n###MEDME-SELF-V2###{\"values\":[]}";
        assert!(parse_self_measurement_payload(text).is_none());
    }

    #[test]
    fn home_ref_range_covers_the_five_supported_analytes_per_design_decision() {
        // 血压/心率:有区间,且带出处。
        for key in ["bp_systolic", "bp_diastolic", "heart_rate"] {
            let r = home_ref_range(key).unwrap_or_else(|| panic!("{key} should have a range"));
            assert!(!r.source.is_empty(), "{key} range must cite a source");
            assert!(r.low.is_some() || r.high.is_some());
        }
        // 体温/体重/血糖:明确不给区间(拍板决定,不是遗漏)。
        for key in ["body_temperature", "body_weight", "glucose"] {
            assert!(
                home_ref_range(key).is_none(),
                "{key} must NOT have a home reference range (see MANUAL-ENTRY-DESIGN.md §5.2/§3.3)"
            );
        }
    }

    #[test]
    fn bp_home_range_is_stricter_than_a_clinic_range() {
        // 135/85 家测阈值,不是诊室的 140/90 —— 这条断言钉住这两个数字不会被
        // 悄悄换成诊室值。
        assert_eq!(home_ref_range("bp_systolic").unwrap().high, Some(135.0));
        assert_eq!(home_ref_range("bp_diastolic").unwrap().high, Some(85.0));
    }
}
