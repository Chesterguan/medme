//! 云抽取结果(deid schema v1)→ `LabObservation`,与 `extract_labs` 的产物同构,
//! 好让 aggregate / assemble_summary / 趋势零改动地吃它。
//!
//! 只吃 labs——meds/diagnoses/impression 仍走 `extract_labs`/`extract_meds`/
//! `extract_conditions` 的正则路径,本模块不碰(Task 11 范围;见 spec §5)。
//!
//! 数值解析、单位换算、"这是不是一条化验行"的证据闸门,三处都直接复用
//! `labs.rs` 给 OCR/正则路径写的同一份函数(`parse_decimal_token`/
//! `canonicalize`/`has_lab_evidence`)——两条路径各自实现一遍、稍有出入,就是
//! 图表安全事故的来源(见这三个函数的文档)。
use crate::labs::{canonicalize, has_lab_evidence, parse_decimal_token, LabObservation};

/// 数值解析:与 `extract_labs` 同一个 `parse_decimal_token`(逗号当小数点),
/// 额外拒收非有限值(`NaN`/`inf`/溢出成 `inf` 的 `1e999`)—— 这些都是"parse
/// 没报错但绝不能拿去 charting"的输入,必须在这里挡,不能留给下游。
fn num(s: &str) -> Option<f64> {
    parse_decimal_token(s.trim()).filter(|v| v.is_finite())
}

/// `labs_from_json` 的成功结果:除了收下来的 labs,还带两个计数,供调用方
/// (Task 12/13 的分享/校验统计)知道这份抽取结果里"没能 charting 的有多少"。
#[derive(Debug, Clone)]
pub struct LabsFromJson {
    pub labs: Vec<LabObservation>,
    /// 因为下列任一原因没进 `labs` 的条目数:数值解析不出有限 `f64`(定性值、
    /// `NaN`/`inf`/畸形字符串),或过不了 `has_lab_evidence` 的证据闸门(裸
    /// 名字+数字,没单位没区间没标记也没词典命中——如 `{"name":"年龄",
    /// "value":"60"}`)。两种原因合并计数:对调用方来说都是"这条不能信,没
    /// charting",具体原因留在本模块内部,不是外部需要分辨的两件事。
    pub dropped_unparseable: usize,
    /// 收进 `labs` 的条目里,`deid::LabItem.unverified == true` 的个数(即
    /// `LabObservation::unverified == true` 的个数)——这些值本身没法逐字核
    /// 实(deid 图片模式),已经带着 `unverified` 标记随 `labs` 一起流向
    /// `aggregate`,这里只是把总数单独报一遍,方便调用方做统计/告警,不必自
    /// 己再数一遍 `labs`。
    pub unverified: usize,
}

/// 把 `deid::Extraction` 的 `labs` 转成 `LabObservation`。
///
/// - `Err` = JSON 解析失败(格式不对、老版本 schema 等)——调用方
///   (`aggregate`)据此退回 `extract_labs` 的正则路径;`Ok` 之后**不再**回退,
///   哪怕 `labs` 里一条都没剩(有效抽取、零条 lab,仍然「用抽取结果」)。
/// - 定性值(如"阴性",解析不出有限 `f64`)不进数值序列——"宁可漏,不能编"。
/// - 裸名字+数字、没有单位/区间/显式标记、词典也认不出的条目(如
///   `{"name":"年龄","value":"60"}`)同样不进——与 `extract_labs` 的
///   `has_lab_evidence` 闸门完全一致,防止把体检单上的年龄/检查号 charting
///   成化验值。
/// - `unverified == true` 的条目照收,`LabObservation::unverified` 原样带
///   上,`confidence` 不受影响(仍是词典匹配的把握,与"这个值有没有核实过"是
///   两回事——见 `LabObservation::unverified` 的文档)。
/// - 词典解析不到的名字原样传出(`analyte_key`/`canonical_name`/`loinc` 为
///   `None`,`confidence` 为 0.0),与 `extract_labs` 对未识别名字的处理一致
///   ——只要它过了证据闸门(比如带着单位)。
pub fn labs_from_json(json: &str) -> Result<LabsFromJson, deid::DeidError> {
    let e = deid::parse_extraction(json)?;
    let mut dropped_unparseable = 0usize;
    let mut unverified = 0usize;
    let labs = e
        .labs
        .iter()
        .filter_map(|l| {
            let value_num = match num(&l.value) {
                Some(v) => v,
                None => {
                    dropped_unparseable += 1;
                    return None;
                }
            };
            let unit = (!l.unit.is_empty()).then(|| l.unit.clone());
            let m = terminology::resolve(&l.name, unit.as_deref());
            let (ref_low, ref_high) = (num(&l.ref_low), num(&l.ref_high));
            let explicit_flag = matches!(l.flag.as_str(), "H" | "L").then(|| l.flag.clone());
            if !has_lab_evidence(
                unit.as_deref(),
                ref_low,
                ref_high,
                explicit_flag.as_deref(),
                m.is_some(),
            ) {
                dropped_unparseable += 1;
                return None;
            }
            // 有参考区间时**自算的比较压过模型给的字面 H/L**:值和区间是证据,
            // 标志是从它们推出来的。两者矛盾时信证据(683 份实测有 7 条矛盾)。
            // 没有区间才回落到字面标志。只改这条 LLM 路,正则路(`labs.rs`)不动。
            let flag = if ref_low.is_some() || ref_high.is_some() {
                if ref_high.is_some_and(|h| value_num > h) {
                    Some("H".into())
                } else if ref_low.is_some_and(|lo| value_num < lo) {
                    Some("L".into())
                } else {
                    Some("N".into())
                }
            } else {
                explicit_flag
            };
            let (value_canonical, unit_canonical, ref_low_canonical, ref_high_canonical) =
                canonicalize(m.as_ref(), unit.as_deref(), value_num, ref_low, ref_high);
            if l.unverified {
                unverified += 1;
            }
            Some(LabObservation {
                raw_name: l.name.clone(),
                analyte_key: m.as_ref().map(|m| m.key.clone()),
                canonical_name: m.as_ref().map(|m| m.canonical_name.clone()),
                loinc: m.as_ref().and_then(|m| m.codes.loinc.clone()),
                value_num,
                value_canonical,
                unit_raw: unit.clone(),
                unit_canonical,
                ref_low,
                ref_high,
                ref_low_canonical,
                ref_high_canonical,
                flag,
                confidence: m.as_ref().map(|m| m.confidence).unwrap_or(0.0),
                self_measured: false,
                unverified: l.unverified,
            })
        })
        .collect();
    Ok(LabsFromJson {
        labs,
        dropped_unparseable,
        unverified,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labs_from_json_resolves_and_flags() {
        let j = r#"{"labs":[
          {"name":"白细胞计数","value":"11.8","unit":"10^9/L","ref_low":"4.0","ref_high":"10.0","flag":""},
          {"name":"血红蛋白","value":"13,5","unit":"g/L","ref_low":"115","ref_high":"150","flag":"","unverified":true},
          {"name":"乙肝表面抗原","value":"阴性","unit":"","ref_low":"","ref_high":"","flag":""}
        ]}"#;
        let r = labs_from_json(j).expect("valid json");
        let v = r.labs;
        assert_eq!(v.len(), 2, "定性值不进数值序列");
        assert_eq!(r.dropped_unparseable, 1, "乙肝表面抗原(阴性)算一条 dropped");
        assert_eq!(r.unverified, 1, "血红蛋白那条 unverified");
        assert_eq!(v[0].flag.as_deref(), Some("H"));
        assert!(v[0].analyte_key.is_some(), "白细胞计数应能解析到词典 key");
        assert!(!v[0].unverified);
        assert_eq!(v[1].value_num, 13.5);
        assert!(v[1].unverified, "unverified 标记要原样带到 LabObservation");
        assert_eq!(
            v[1].confidence, 1.0,
            "confidence 只反映词典匹配把握,不因 unverified 而降低——两者是两件事"
        );
    }

    /// 有参考区间时,自算的比较**压过**模型给的字面 H/L —— 值和区间是证据,
    /// 标志是从它们推出来的。没有区间才认字面标志。
    #[test]
    fn computed_flag_beats_the_literal_one_when_a_range_is_present() {
        // 值落在区间内,模型却给了 H:信区间,出 N
        let j = r#"{"labs":[{"name":"白细胞计数","value":"5.6","unit":"10^9/L","ref_low":"4.0","ref_high":"10.0","flag":"H"}]}"#;
        assert_eq!(
            labs_from_json(j).expect("valid json").labs[0]
                .flag
                .as_deref(),
            Some("N")
        );
        // 值确实超上限,模型给了 L:同样信区间,出 H
        let j = r#"{"labs":[{"name":"白细胞计数","value":"11.8","unit":"10^9/L","ref_low":"4.0","ref_high":"10.0","flag":"L"}]}"#;
        assert_eq!(
            labs_from_json(j).expect("valid json").labs[0]
                .flag
                .as_deref(),
            Some("H")
        );
        // 没有区间可算,字面标志仍然作数
        let j = r#"{"labs":[{"name":"白细胞计数","value":"11.8","unit":"10^9/L","ref_low":"","ref_high":"","flag":"H"}]}"#;
        assert_eq!(
            labs_from_json(j).expect("valid json").labs[0]
                .flag
                .as_deref(),
            Some("H")
        );
    }

    #[test]
    fn labs_from_json_malformed_is_err() {
        assert!(labs_from_json("not json").is_err());
    }

    #[test]
    fn labs_from_json_empty_object_is_ok_with_zero_labs() {
        let r = labs_from_json("{}").expect("empty extraction is still valid json");
        assert_eq!(r.labs.len(), 0);
        assert_eq!(r.dropped_unparseable, 0);
    }

    /// 未识别的名字**只要带着别的证据**(这里是单位)仍要原样传出——与
    /// `extract_labs` 对未识别名字的处理一致,不能因为词典没认出就整条扔掉。
    #[test]
    fn labs_from_json_unknown_name_with_unit_passes_through() {
        let j = r#"{"labs":[{"name":"某罕见指标XYZ","value":"1.0","unit":"IU/mL","ref_low":"","ref_high":"","flag":""}]}"#;
        let r = labs_from_json(j).expect("valid json");
        assert_eq!(r.labs.len(), 1);
        assert!(r.labs[0].analyte_key.is_none());
        assert_eq!(r.labs[0].confidence, 0.0);
        assert_eq!(r.labs[0].raw_name, "某罕见指标XYZ");
    }

    /// 证据闸门:裸名字+数字,没单位没区间没标记也没词典命中——年龄/检查号一类
    /// 的元数据,不能 charting 成化验值(与 `labs.rs` 的 `has_lab_evidence` 同
    /// 一条闸门)。
    #[test]
    fn labs_from_json_bare_name_and_number_without_evidence_is_dropped() {
        let j = r#"{"labs":[{"name":"年龄","value":"60","unit":"","ref_low":"","ref_high":"","flag":""}]}"#;
        let r = labs_from_json(j).expect("valid json");
        assert_eq!(r.labs.len(), 0, "没有单位/区间/标记/词典命中,不该 charting");
        assert_eq!(r.dropped_unparseable, 1);
    }

    /// `NaN`/`inf`/溢出成 `inf` 的数值字符串:parse 不报错,但绝不能当成真实
    /// 结果 charting——`is_finite()` 必须把它们全部挡在 `labs` 外面。
    #[test]
    fn labs_from_json_non_finite_values_are_dropped_and_counted() {
        let j = r#"{"labs":[
          {"name":"肌酐","value":"NaN","unit":"umol/L","ref_low":"","ref_high":"","flag":""},
          {"name":"肌酐","value":"inf","unit":"umol/L","ref_low":"","ref_high":"","flag":""},
          {"name":"肌酐","value":"1e999","unit":"umol/L","ref_low":"","ref_high":"","flag":""}
        ]}"#;
        let r = labs_from_json(j).expect("valid json");
        assert_eq!(r.labs.len(), 0, "NaN/inf/溢出成 inf 一个都不能进 labs");
        assert_eq!(r.dropped_unparseable, 3);
    }

    /// 单位换算只在词典真认识这份印刷单位时才产出——与 `labs.rs` 的
    /// `canonicalize` 完全一致的闸门。这里给一个词典不认识的单位(伪造),
    /// 换算应整体留空,而不是恒等式地把印刷值直接当规范值。
    #[test]
    fn labs_from_json_unit_conversion_is_none_when_dictionary_does_not_know_the_unit() {
        let j = r#"{"labs":[{"name":"肌酐","value":"1.2","unit":"某种词典不认识的单位","ref_low":"","ref_high":"","flag":""}]}"#;
        let r = labs_from_json(j).expect("valid json");
        assert_eq!(r.labs.len(), 1);
        assert_eq!(
            r.labs[0].value_canonical, None,
            "词典不认识这个印刷单位,规范值必须是 None,不能恒等式地照抄印刷值"
        );
        assert_eq!(r.labs[0].unit_canonical, None);
    }
}
