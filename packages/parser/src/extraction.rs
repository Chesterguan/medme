//! 云抽取结果(deid schema v1)→ `LabObservation`,与 `extract_labs` 的产物同构,
//! 好让 aggregate / assemble_summary / 趋势零改动地吃它。
//!
//! 只吃 labs——meds/diagnoses/impression 仍走 `extract_labs`/`extract_meds`/
//! `extract_conditions` 的正则路径,本模块不碰(Task 11 范围;见 spec §5)。
use crate::labs::LabObservation;

/// 数值解析:与 `extract_labs` 同款宽容度(逗号当小数点),不额外收紧也不放宽。
fn num(s: &str) -> Option<f64> {
    s.trim().replace(',', ".").parse::<f64>().ok()
}

/// 把 `deid::Extraction` 的 `labs` 转成 `LabObservation`。
///
/// - 定性值(如"阴性",解析不出 f64)不进数值序列——"宁可漏,不能编"。
/// - `unverified == true` 的条目照收,但 `confidence` 压到 0.5,送人工核对
///   (不是丢弃:图片档校验不过≠假,只是没法逐字核实)。
/// - 词典解析不到的名字原样传出(`analyte_key`/`canonical_name`/`loinc` 为
///   `None`,`confidence` 为 0.0),与 `extract_labs` 对未识别名字的处理一致。
/// - JSON 解析失败(格式不对、老版本 schema 等)返回空 vec——供不关心「为什么
///   没有」的调用方直接用。`aggregate` 自己要区分「有效但零条」与「解析失败」
///   (后者要退回 `extract_labs`),走的是 [`try_labs_from_json`]。
pub fn labs_from_json(json: &str) -> Vec<LabObservation> {
    try_labs_from_json(json).unwrap_or_default()
}

/// `labs_from_json` 的可失败版本:`None` = JSON 解析失败(该退回
/// `extract_labs` 走正则路径),`Some(_)`(可能是空 vec)= 解析成功、按抽取结果
/// 走,即使这份文档里 LLM 没给出任何 lab。`aggregate` 用这个区分两种情况——
/// 只看 `labs_from_json` 拿到的空 vec 分不清"零条"和"解析失败"。
pub(crate) fn try_labs_from_json(json: &str) -> Option<Vec<LabObservation>> {
    let e = deid::parse_extraction(json).ok()?;
    Some(labs_from_extraction(&e))
}

fn labs_from_extraction(e: &deid::Extraction) -> Vec<LabObservation> {
    e.labs
        .iter()
        .filter_map(|l| {
            let value_num = num(&l.value)?;
            let unit = (!l.unit.is_empty()).then(|| l.unit.clone());
            let m = terminology::resolve(&l.name, unit.as_deref());
            let (ref_low, ref_high) = (num(&l.ref_low), num(&l.ref_high));
            let flag = match l.flag.as_str() {
                "H" | "L" => Some(l.flag.clone()),
                _ if ref_high.is_some_and(|h| value_num > h) => Some("H".into()),
                _ if ref_low.is_some_and(|lo| value_num < lo) => Some("L".into()),
                _ if ref_low.is_some() || ref_high.is_some() => Some("N".into()),
                _ => None,
            };
            Some(LabObservation {
                raw_name: l.name.clone(),
                analyte_key: m.as_ref().map(|m| m.key.clone()),
                canonical_name: m.as_ref().map(|m| m.canonical_name.clone()),
                loinc: m.as_ref().and_then(|m| m.codes.loinc.clone()),
                value_num,
                // ponytail: 规范单位换算未接(与自测值同款恒等换算);跨院混单位
                // 画趋势时接 labs.rs 的 UnitConversion。
                value_canonical: Some(value_num),
                unit_raw: unit.clone(),
                unit_canonical: unit,
                ref_low,
                ref_high,
                ref_low_canonical: ref_low,
                ref_high_canonical: ref_high,
                flag,
                // labs.rs:160——0.0 = 词典没认出;unverified(图片档校验不过)压到
                // 0.5 送人工核对。
                confidence: if l.unverified {
                    0.5
                } else {
                    m.as_ref().map(|m| m.confidence).unwrap_or(0.0)
                },
                self_measured: false,
            })
        })
        .collect()
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
        let v = labs_from_json(j);
        assert_eq!(v.len(), 2, "定性值不进数值序列");
        assert_eq!(v[0].flag.as_deref(), Some("H"));
        assert!(v[0].analyte_key.is_some(), "白细胞计数应能解析到词典 key");
        assert_eq!(v[1].value_num, 13.5);
        assert!(v[1].confidence < 1.0, "unverified 降置信度");
    }

    #[test]
    fn labs_from_json_malformed_returns_empty() {
        assert_eq!(labs_from_json("not json").len(), 0);
    }

    #[test]
    fn try_labs_from_json_distinguishes_malformed_from_empty() {
        assert!(
            try_labs_from_json("not json").is_none(),
            "解析失败 → None,退回 extract_labs"
        );
        assert_eq!(
            try_labs_from_json("{}").map(|v| v.len()),
            Some(0),
            "有效 JSON 但零条 labs → Some(空 vec),仍算「用抽取结果」"
        );
    }

    #[test]
    fn labs_from_json_unknown_name_passthrough() {
        let j = r#"{"labs":[{"name":"某罕见指标XYZ","value":"1.0","unit":"","ref_low":"","ref_high":"","flag":""}]}"#;
        let v = labs_from_json(j);
        assert_eq!(v.len(), 1);
        assert!(v[0].analyte_key.is_none());
        assert_eq!(v[0].confidence, 0.0);
        assert_eq!(v[0].raw_name, "某罕见指标XYZ");
    }
}
