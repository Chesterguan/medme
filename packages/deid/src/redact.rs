//! 三层组合。顺序即优先级:K(已知值)→ A(锚点)→ P(模式)→ 日期偏移。
use crate::{anchors, dates, known, patterns};
use serde::{Deserialize, Serialize};

pub use known::KnownIdentity;

/// 占位符 ↔ 原文。**永不离开手机。**
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
pub struct RestoreMap {
    pub placeholders: Vec<(String, String)>,
    pub shift_days: i64,
}

impl RestoreMap {
    /// 同一原文只发一个占位符(同一医院名出现三次 → 三处同一个 [H1])。
    pub fn placeholder(&mut self, kind: &str, value: &str) -> String {
        if let Some((p, _)) = self.placeholders.iter().find(|(_, v)| v == value) {
            return p.clone();
        }
        let n = self.placeholders.iter().filter(|(p, _)| p.starts_with(&format!("[{kind}"))).count() + 1;
        let p = format!("[{kind}{n}]");
        self.placeholders.push((p.clone(), value.to_string()));
        p
    }
}

pub struct Redacted {
    pub text: String,
    pub map: RestoreMap,
}

pub fn redact_text(text: &str, known: &KnownIdentity, shift_days: i64) -> Redacted {
    let mut map = RestoreMap { placeholders: Vec::new(), shift_days };
    let t = known::apply(text, known, &mut map);
    let t = anchors::apply(&t, &mut map);
    let t = patterns::apply(&t, &mut map);
    let t = dates::shift_dates(&t, shift_days);
    Redacted { text: t, map }
}

/// 先减日期,再把占位符按登记顺序倒着换回(后登记的可能嵌在先登记的里)。
pub fn restore(text: &str, map: &RestoreMap) -> String {
    let mut out = dates::unshift_dates(text, map.shift_days);
    for (p, v) in map.placeholders.iter().rev() {
        out = out.replace(p, v);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn known() -> KnownIdentity {
        KnownIdentity { name: "孟丁".into(), id_number: Some("110101199001011234".into()), phone: Some("13800138000".into()) }
    }

    #[test]
    fn known_name_is_removed_even_when_glued() {
        let r = redact_text("姓名孟丁性别男 年龄2岁 门诊号90051065 科室儿科", &known(), 0);
        assert!(!r.text.contains("孟丁"), "{}", r.text);
        assert!(r.text.contains("性别男"), "性别保留:{}", r.text);
        assert!(r.text.contains("年龄2岁"), "年龄保留:{}", r.text);
        assert!(r.text.contains("科室儿科"), "科室保留:{}", r.text);
        assert!(!r.text.contains("90051065"), "门诊号掩掉:{}", r.text);
    }

    #[test]
    fn anchors_mask_value_and_doctor_names() {
        let r = redact_text("北京协和医院检验报告\n姓名:张建国  性别:男  年龄:60岁 病案号:62198842\n审核者樊笋  检验者:王涛", &known(), 0);
        assert!(!r.text.contains("张建国") && !r.text.contains("62198842") && !r.text.contains("樊笋") && !r.text.contains("王涛"), "{}", r.text);
        assert!(!r.text.contains("北京协和医院"), "医院名掩成 [H1]:{}", r.text);
        assert!(r.text.contains("[H1]"), "{}", r.text);
        assert!(r.text.contains("年龄:60岁"), "{}", r.text);
    }

    #[test]
    fn patterns_catch_id_phone_long_digits_url() {
        let r = redact_text("条码 2023061512345 电话 010-69156114 手机13912345678 身份证 44010519850101123X 网址 www.pumch.cn 白细胞 5.6 4.0-10.0", &known(), 0);
        for leak in ["2023061512345", "69156114", "13912345678", "44010519850101123X", "www.pumch.cn"] {
            assert!(!r.text.contains(leak), "{leak} 漏了:{}", r.text);
        }
        assert!(r.text.contains("白细胞 5.6 4.0-10.0"), "检验值与区间不动:{}", r.text);
    }

    #[test]
    fn restore_puts_everything_back() {
        let src = "北京协和医院 姓名:张建国 采集时间:2024-03-05 门诊号:20230615-1046";
        let r = redact_text(src, &known(), 7);
        assert!(r.text.contains("2024-03-12"), "{}", r.text);
        let back = restore(&r.text, &r.map);
        assert_eq!(back, src);
    }

    // --- fix round 1: 复现审阅发现的泄漏/误伤,逐条钉住 ---

    #[test]
    fn dot_or_dash_lead_in_no_longer_swallows_the_whole_number() {
        // 旧实现:紧邻 `.`/`-` 就当成小数/区间跳过,不管另一侧是不是数字——
        // 结果座机号、条码号整段漏网。三条各占一行,避免和「化验行豁免」(item4)的
        // 行级判断互相干扰——那条规则本身在 patterns.rs 的测试里单独钉住了。
        let r = redact_text(
            "电话010-69156114\n编号No.2023061512345\n参考 100000-300000",
            &known(),
            0,
        );
        assert!(!r.text.contains("69156114"), "座机号漏了:{}", r.text);
        assert!(!r.text.contains("2023061512345"), "条码号漏了:{}", r.text);
        assert!(r.text.contains("100000-300000"), "参考区间不该被掩:{}", r.text);
    }

    #[test]
    fn adjacent_long_digit_runs_are_all_masked_not_just_the_first() {
        // 旧实现:消费型正则把分隔符吃进上一个匹配,下一个数字串就找不到合法起点了。
        let r = redact_text("90051065/62198842", &known(), 0);
        assert!(!r.text.contains("90051065") && !r.text.contains("62198842"), "{}", r.text);

        let r2 = redact_text("111111 222222 333333", &known(), 0);
        for leak in ["111111", "222222", "333333"] {
            assert!(!r2.text.contains(leak), "{leak} 漏了:{}", r2.text);
        }
    }

    #[test]
    fn anchor_id_and_ward_values_are_not_truncated_by_a_character_cap() {
        // 旧实现:锚点值上限 12 字符,18 位身份证号/16 位住院号被拦腰截断,尾巴明文残留。
        let src = "身份证号44010519850101123X 住院号:1234567890123456";
        let r = redact_text(src, &known(), 0);
        assert!(!r.text.contains("44010519850101123X"), "{}", r.text);
        assert!(!r.text.contains("1234567890123456"), "{}", r.text);
        for tail in ["01123X", "3456"] {
            assert!(!r.text.contains(tail), "残留尾巴 {tail}:{}", r.text);
        }
        let back = restore(&r.text, &r.map);
        assert_eq!(back, src);
    }

    #[test]
    fn compact_date_is_shifted_not_masked_and_round_trips() {
        let src = "采集时间20240305";
        let r = redact_text(src, &known(), 7);
        assert!(r.text.contains("20240312"), "紧凑日期该偏移而不是掩码:{}", r.text);
        let back = restore(&r.text, &r.map);
        assert_eq!(back, src);
    }

    #[test]
    fn name_anchor_value_stops_at_next_anchor_word_even_when_glued() {
        let unrelated = KnownIdentity { name: "赵六".into(), id_number: None, phone: None };
        let r = redact_text("姓名孟丁性别男门诊号90051065", &unrelated, 0);
        assert_eq!(r.text, "姓名[P1]性别男门诊号[N1]");
    }

    #[test]
    fn bare_doctor_and_patient_words_are_not_anchors() {
        let a = redact_text("患者主诉发热三天 无咳嗽", &known(), 0);
        assert_eq!(a.text, "患者主诉发热三天 无咳嗽");
        let b = redact_text("医生建议复查肝功能", &known(), 0);
        assert_eq!(b.text, "医生建议复查肝功能");
    }

    #[test]
    fn repeated_value_reuses_the_same_numbered_placeholder() {
        let r = redact_text("审核者樊笋 复核 审核者樊笋", &known(), 0);
        let p_count = r.map.placeholders.iter().filter(|(p, _)| p.starts_with("[P")).count();
        assert_eq!(p_count, 1, "同一个值该只分配一个占位符:{:?}", r.map.placeholders);
        assert_eq!(r.text.matches("[P1]").count(), 2, "{}", r.text);
    }

    #[test]
    fn lab_row_units_age_and_sex_all_survive() {
        let r = redact_text(
            "性别:男 年龄:45岁 白细胞 5.6 10^9/L 血小板 120000 参考 100000-300000",
            &known(),
            0,
        );
        for keep in ["性别:男", "年龄:45岁", "白细胞 5.6", "10^9/L", "血小板 120000", "100000-300000"] {
            assert!(r.text.contains(keep), "{keep} 应保留:{}", r.text);
        }
    }
}
