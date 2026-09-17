//! 病程档案的**用户动作日志**(spec §4)。
//!
//! 与 [`crate::self_entry`] 完全同构,理由也一样:这段文本既由我们写、也由我们读,
//! 所以带一条精确的、带版本的机器可读载荷,读回时逐字反序列化,不用模糊正则。
//!
//! 这些事件必须落日志(而不是存在某个本地偏好里),因为它们要跟着保险箱同步到
//! 别的设备、要进加密分享、并且档案永远可以从日志重算(spec §0)。
use serde::{Deserialize, Serialize};

/// 载荷行的哨兵 + 显式版本。格式变了就升版本,老代码读到新版本**失败关闭**
/// ([`parse_profile_event_payload`] → `None`),而不是把新形状猜着读一半。
pub const PROFILE_EVENT_MARKER: &str = "###MEDME-PROFILE-V1###";

/// 一条用户动作。
///
/// `kind` 取值(spec §4):`enable` / `disable` / `confirm_dx` / `reject_dx` /
/// `flare` / `symptom_score` / `pga` / `dismiss_reminder` / `drug_start` /
/// `drug_stop` / `infusion` / `weight`。
///
/// `payload` 刻意是 `serde_json::Value`:每种 kind 的形状不一样,而规则引擎只按
/// kind 取自己认得的那几个键。认不出的 kind 原样躺在日志里,将来的版本能读它 ——
/// 这是「永远可重算」的前提。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileEvent {
    pub kind: String,
    /// 包 id(`"sle"`)。一个保险箱可以同时开多个病。
    pub package: String,
    /// 事件发生日期 `YYYY-MM-DD`(用户说的那天,不是记录那天)。
    pub at: String,
    #[serde(default)]
    pub payload: serde_json::Value,
}

/// 合成 `ocr_result.text`:调用方给的人读文字在前,空行,再是载荷行。
/// 措辞全由调用方决定(本模块对文案没有意见),这里只管结构化的那条尾巴。
pub fn render_profile_event_text(human_lines: &[String], ev: &ProfileEvent) -> String {
    let mut out = human_lines.join("\n");
    out.push_str("\n\n");
    out.push_str(PROFILE_EVENT_MARKER);
    out.push_str(&serde_json::to_string(ev).expect("ProfileEvent 全是 String/Value,恒可序列化"));
    out
}

/// 从 `doc_type == "profile_event"` 文档的文本里读回载荷。哨兵不在、版本不符、
/// JSON 坏了,一律 `None` —— 从不猜半份。
pub fn parse_profile_event_payload(text: &str) -> Option<ProfileEvent> {
    let line = text.lines().find(|l| l.starts_with(PROFILE_EVENT_MARKER))?;
    serde_json::from_str(line.strip_prefix(PROFILE_EVENT_MARKER)?).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev() -> ProfileEvent {
        ProfileEvent {
            kind: "enable".into(),
            package: "sle".into(),
            at: "2026-09-16".into(),
            payload: serde_json::json!({}),
        }
    }

    #[test]
    fn render_then_parse_round_trips() {
        let text = render_profile_event_text(&["开启了狼疮病程档案".to_string()], &ev());
        assert!(
            text.starts_with("开启了狼疮病程档案"),
            "人读的那几行必须在最前面"
        );
        let back = parse_profile_event_payload(&text).expect("能读回来");
        assert_eq!(back.kind, "enable");
        assert_eq!(back.package, "sle");
        assert_eq!(back.at, "2026-09-16");
    }

    #[test]
    fn payload_survives_verbatim() {
        let mut e = ev();
        e.kind = "symptom_score".into();
        e.payload = serde_json::json!({"items": ["arthritis", "rash"], "total": 6});
        let back = parse_profile_event_payload(&render_profile_event_text(&[], &e)).unwrap();
        assert_eq!(back.payload, e.payload);
    }

    #[test]
    fn a_wrong_version_marker_returns_none_instead_of_guessing() {
        let text = render_profile_event_text(&[], &ev()).replace("V1", "V2");
        assert!(parse_profile_event_payload(&text).is_none());
    }

    #[test]
    fn corrupt_json_returns_none() {
        let text = format!("人读的一行\n\n{PROFILE_EVENT_MARKER}{{not json");
        assert!(parse_profile_event_payload(&text).is_none());
    }

    #[test]
    fn a_self_measurement_document_is_not_mistaken_for_a_profile_event() {
        let sm = crate::render_self_measurement_text(
            &["体重 61 kg".to_string()],
            &[crate::SelfMeasuredValue {
                analyte_key: "body_weight".into(),
                value: 61.0,
                unit: "kg".into(),
            }],
        );
        assert!(parse_profile_event_payload(&sm).is_none());
    }
}
