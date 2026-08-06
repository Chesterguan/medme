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

/// A physiological **plausibility** bound for `analyte_key` — deliberately a
/// different concept from [`HomeRefRange`]/[`home_ref_range`], and much wider.
/// `home_ref_range` judges "normal vs. elevated" for values that are already
/// known to be real measurements; this judges only "could this number ever
/// occur on a human body", to catch fat-finger entry (a real Mate 9 field
/// report: a user meant to type systolic 138 and the digit repeated into
/// 138388 — six digits, no device on earth reads that, but nothing stopped it
/// from being saved). A value can be *outside* `home_ref_range` (elevated/
/// dangerous) while still comfortably *inside* this range — e.g. 200/110
/// mmHg is a real hypertensive-crisis reading and MUST remain storable and
/// flagged "H" downstream; only [`home_ref_range`] decides that flag, this
/// function never rejects on it. Only values outside this range are rejected
/// at write time — see [`validate_self_measured_values`].
pub struct PlausibleRange {
    pub low: f64,
    pub high: f64,
    pub source: &'static str,
}

/// The plausibility bound for `analyte_key`, or `None` for a key this module
/// doesn't recognize (falls through with no gate, same "unknown key doesn't
/// crash" posture as [`home_ref_range`]). Every one of the six keys the
/// mobile picker can produce has a bound — unlike `home_ref_range`, there is
/// no "no defensible range" case here: even body_weight/glucose (which have
/// no clinical normal/high judgment) still have a plausible *physical* upper
/// and lower bound.
pub fn plausible_range(analyte_key: &str) -> Option<PlausibleRange> {
    match analyte_key {
        "bp_systolic" => Some(PlausibleRange {
            low: 60.0,
            high: 260.0,
            source: "未核实到具体出处,取值依据是生理学极限的保守外扩:收缩压\
                低于 60 mmHg 已属重度低血压/休克范畴,常规示波法血压计在此\
                区间以下多半已测不出稳定读数;260 mmHg 高于临床上作为\"高血压\
                危象\"报告的极端病例,取整数上限留出余量 —— 不是某一部指南\
                给出的切点。",
        }),
        "bp_diastolic" => Some(PlausibleRange {
            low: 30.0,
            high: 160.0,
            source: "未核实到具体出处,取值依据同收缩压(见 bp_systolic 的\
                注释):30 mmHg 以下、160 mmHg 以上都超出常规血压计示波法\
                测量的可信区间,是生理学极限的保守外扩,不是某一部指南给出的\
                切点。",
        }),
        "heart_rate" => Some(PlausibleRange {
            low: 25.0,
            high: 250.0,
            source: "未核实到具体出处,取值依据是生理学极限的保守外扩:成人\
                静息心率低于 25 次/分已接近严重心动过缓/心脏停搏边缘,高于\
                250 次/分超出心脏电生理能维持有效搏出的上限,两端都留了\
                余量。",
        }),
        "body_temperature" => Some(PlausibleRange {
            low: 30.0,
            high: 45.0,
            source: "未核实到具体出处,取值依据是生理学极限的保守外扩:体温\
                低于 30°C 已属重度低体温,高于 45°C 已超出人类已知存活体温\
                记录的保守外扩;常规体温计的量程也大多落在此区间之内。",
        }),
        "body_weight" => Some(PlausibleRange {
            low: 1.0,
            high: 400.0,
            source: "未核实到具体出处,取值依据是生理学极限的保守外扩:1 kg\
                以下不是本应用自测场景会出现的体重,400 kg 超出常见家用体重\
                秤的量程上限,也远高于已报道的极端病例体重。",
        }),
        "glucose" => Some(PlausibleRange {
            low: 1.0,
            high: 40.0,
            source: "未核实到具体出处,取值依据是生理学极限的保守外扩:\
                1 mmol/L 以下已低于可测出的血糖下限(严重低血糖昏迷阈值\
                约 2.8 mmol/L 之下留了余量),40 mmol/L 远高于常见家用血糖仪\
                的量程上限(通常 33.3 mmol/L 封顶),留出余量避免卡住真实的\
                极端高血糖读数。",
        }),
        _ => None,
    }
}

/// Why [`validate_self_measured_values`] rejected a batch. Deliberately
/// structured rather than a pre-formatted string — this crate has no UI
/// vocabulary of its own (the Chinese analyte labels live in
/// `api::vault::self_measured_label`), so the FFI layer formats the final
/// message; this only carries the facts.
#[derive(Debug, Clone, PartialEq)]
pub enum PlausibilityViolation {
    /// `value` for `analyte_key` fell outside `[low, high]`.
    OutOfRange {
        analyte_key: String,
        value: f64,
        low: f64,
        high: f64,
    },
    /// Both blood-pressure values were present but systolic didn't exceed
    /// diastolic — almost always a transposed entry (e.g. 88/138), not a
    /// real reading.
    SystolicNotAboveDiastolic { systolic: f64, diastolic: f64 },
}

/// Reject values that cannot physically occur, before they're written.
/// **Not** a clinical judgment — see [`plausible_range`]'s doc for the hard
/// distinction from [`home_ref_range`]. Checks, in order: (1) each value
/// against its own [`plausible_range`]; (2) if both blood-pressure values are
/// present, that systolic exceeds diastolic (a per-value range can't express
/// this — a lone 88 or a lone 138 is plausible for *either* field, the
/// problem only shows up comparing the pair). Returns the first violation
/// found; callers needing every violation at once don't currently exist.
///
/// This is the backstop for `manual_entry_sheet.dart`'s pre-save check
/// (`self_entry` is the one path all self-measured data goes through — see
/// `add_self_measurement`), not the primary UX: the Dart layer already runs
/// the same check with more guided phrasing before this is ever reached in
/// normal use, so this only fires if some future entry point bypasses the UI
/// layer.
pub fn validate_self_measured_values(
    values: &[SelfMeasuredValue],
) -> Result<(), PlausibilityViolation> {
    for v in values {
        if let Some(range) = plausible_range(&v.analyte_key) {
            if v.value < range.low || v.value > range.high {
                return Err(PlausibilityViolation::OutOfRange {
                    analyte_key: v.analyte_key.clone(),
                    value: v.value,
                    low: range.low,
                    high: range.high,
                });
            }
        }
    }
    let systolic = values
        .iter()
        .find(|v| v.analyte_key == "bp_systolic")
        .map(|v| v.value);
    let diastolic = values
        .iter()
        .find(|v| v.analyte_key == "bp_diastolic")
        .map(|v| v.value);
    if let (Some(systolic), Some(diastolic)) = (systolic, diastolic) {
        if systolic <= diastolic {
            return Err(PlausibilityViolation::SystolicNotAboveDiastolic {
                systolic,
                diastolic,
            });
        }
    }
    Ok(())
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

    fn v(analyte_key: &str, value: f64, unit: &str) -> SelfMeasuredValue {
        SelfMeasuredValue {
            analyte_key: analyte_key.into(),
            value,
            unit: unit.into(),
        }
    }

    #[test]
    fn plausible_range_covers_all_six_supported_analytes_with_a_source() {
        // 与 home_ref_range 不同:六个自测项全部要有可能性范围(体重/血糖也
        // 有物理上限,即使没有临床正常/偏高判断)。
        for key in [
            "bp_systolic",
            "bp_diastolic",
            "heart_rate",
            "body_temperature",
            "body_weight",
            "glucose",
        ] {
            let r = plausible_range(key).unwrap_or_else(|| panic!("{key} should have a range"));
            assert!(!r.source.is_empty(), "{key} range must cite a source");
            assert!(r.low < r.high);
        }
        assert!(plausible_range("not_a_real_key").is_none());
    }

    #[test]
    fn rejects_an_impossible_six_digit_systolic_value() {
        // 真机实测:华为 Mate 9 上手填收缩压时存进了 138388 mmHg —— 物理上
        // 不存在,必须拒绝保存,而不是原样存进去把趋势图 Y 值域拉爆。
        let err = validate_self_measured_values(&[
            v("bp_systolic", 138388.0, "mmHg"),
            v("bp_diastolic", 82.0, "mmHg"),
        ])
        .unwrap_err();
        assert_eq!(
            err,
            PlausibilityViolation::OutOfRange {
                analyte_key: "bp_systolic".into(),
                value: 138388.0,
                low: 60.0,
                high: 260.0,
            }
        );
    }

    #[test]
    fn accepts_a_real_hypertensive_crisis_reading() {
        // 200/110 是真实且危险的血压,不是打错 —— 必须存得进去(这条断言钉住
        // "范围外拒绝/范围内即使超参考区间也要放行"这两者不会被混成一刀切
        // 拒绝)。是否标"偏高"是 home_ref_range/aggregate 的职责,这里只管
        // "可不可能存在"。
        assert!(validate_self_measured_values(&[
            v("bp_systolic", 200.0, "mmHg"),
            v("bp_diastolic", 110.0, "mmHg"),
        ])
        .is_ok());
        // 同理:体温 40°C(高热但真实)、心率 180(运动/心动过速但真实)都必须
        // 放行。
        assert!(validate_self_measured_values(&[v("body_temperature", 40.0, "Cel")]).is_ok());
        assert!(validate_self_measured_values(&[v("heart_rate", 180.0, "/min")]).is_ok());
    }

    #[test]
    fn rejects_transposed_systolic_and_diastolic() {
        // 88/138:两个值各自都在可能性范围内,但收缩压<=舒张压 —— 交叉校验
        // 才能挡住这种"填反了"的输入,单值域校验挡不住。
        let err = validate_self_measured_values(&[
            v("bp_systolic", 88.0, "mmHg"),
            v("bp_diastolic", 138.0, "mmHg"),
        ])
        .unwrap_err();
        assert_eq!(
            err,
            PlausibilityViolation::SystolicNotAboveDiastolic {
                systolic: 88.0,
                diastolic: 138.0,
            }
        );
    }

    #[test]
    fn equal_systolic_and_diastolic_is_also_rejected() {
        // 收缩压必须严格大于舒张压,相等也不成立(不是真实生理状态)。
        let err = validate_self_measured_values(&[
            v("bp_systolic", 100.0, "mmHg"),
            v("bp_diastolic", 100.0, "mmHg"),
        ])
        .unwrap_err();
        assert_eq!(
            err,
            PlausibilityViolation::SystolicNotAboveDiastolic {
                systolic: 100.0,
                diastolic: 100.0,
            }
        );
    }

    #[test]
    fn single_value_entries_are_only_checked_against_their_own_range() {
        // 心率/体重/体温/血糖各自单独一条记录,没有配对字段可交叉校验——只走
        // 范围检查这一条路径。
        assert!(validate_self_measured_values(&[v("heart_rate", 25.0, "/min")]).is_ok());
        assert!(validate_self_measured_values(&[v("heart_rate", 250.0, "/min")]).is_ok());
        assert!(validate_self_measured_values(&[v("heart_rate", 24.9, "/min")]).is_err());
        assert!(validate_self_measured_values(&[v("heart_rate", 250.1, "/min")]).is_err());
    }

    #[test]
    fn unknown_analyte_key_has_no_gate_and_is_never_rejected() {
        // 未知 key(理论上不会发生,五选一界面产出的 key 是封闭的)不该崩,也
        // 不该被这层拒绝——与 home_ref_range 对陌生 key 的 `_ => None` 兜底
        // 同一姿势。
        assert!(validate_self_measured_values(&[v("mystery_analyte", 9e9, "?")]).is_ok());
    }
}
