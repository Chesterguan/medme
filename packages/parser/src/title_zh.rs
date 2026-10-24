//! Epic 英文文档标题 → 中文显示标题(2026-10-23 中文化 spec §2.1.3)。
//!
//! **只在显示层用**:`DocumentAdded.title` 只写一次,改适配器要删掉重导,所以映射放这里,
//! 手机 DTO(`title_zh`)与分享包(`records[].title_zh`)同一来源。已是中文/混合的标题返回
//! `None`,不二次映射;认不出的英文标题也 `None`,界面保留原文。

/// 整串精确表(大小写不敏感、首尾空白忽略):Epic `SECTION_DOC_TYPE` 的 8 个小节名 + 影像小节名。
const EXACT: &[(&str, &str)] = &[
    ("discharge summary note", "出院小结"),
    ("h&p notes", "入院记录"),
    ("ed provider note", "急诊医生记录"),
    ("ed notes", "急诊记录"),
    ("ed record", "急诊病历"),
    ("operative notes", "手术记录"),
    ("reason for visit", "就诊原因"),
    ("visit information", "就诊信息"),
    ("progress notes", "病程记录"),
    ("radiology", "影像"),
    ("imaging", "影像"),
];

/// 就诊类型前缀(适配器 `"%s %s" % (enc_kind, dept)` 的 enc_kind 部分)→ 中文;余下科室原文保留。
/// 最长前缀先匹配(`ED to Hosp-Admission` 必须排在 `ED` 前面,靠排序而不是靠写的顺序)。
const ENCOUNTER_PREFIX: &[(&str, &str)] = &[
    ("ed to hosp-admission", "急诊收入院"),
    ("hospital encounter", "住院"),
    ("inpatient", "住院"),
    ("emergency", "急诊"),
    ("ed", "急诊"),
    ("office visit", "门诊"),
    ("telemedicine", "远程就诊"),
    ("telephone", "电话随访"),
    ("procedure", "操作/检查"),
];

/// 影像检查方式前缀(词边界)→ 中文;部位/造影原文保留。
const MODALITY_PREFIX: &[(&str, &str)] = &[
    ("mri", "磁共振"),
    ("mr", "磁共振"),
    ("ct", "CT"),
    ("xr", "X线"),
    ("us", "超声"),
    ("echo", "心脏超声"),
    ("nm", "核医学"),
    ("pet", "PET"),
];

fn has_cjk(s: &str) -> bool {
    s.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c))
}

/// 大小写不敏感地剥前缀,且前缀后必须是词边界(串尾、空白或 `(`);返回余下部分(已去首空白)。
fn strip_prefix_ci<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    if s.len() < prefix.len() || !s.is_char_boundary(prefix.len()) {
        return None;
    }
    let (head, rest) = s.split_at(prefix.len());
    if !head.eq_ignore_ascii_case(prefix) {
        return None;
    }
    match rest.chars().next() {
        None => Some(""),
        Some(c) if c.is_whitespace() || c == '(' => Some(rest.trim_start()),
        _ => None,
    }
}

/// 去掉开头的一段括号注记(`(Discharged) UF 65MS` → `UF 65MS`)。
fn drop_leading_paren(s: &str) -> &str {
    if let Some(rest) = s.strip_prefix('(') {
        if let Some(i) = rest.find(')') {
            return rest[i + 1..].trim_start();
        }
    }
    s
}

fn join(zh: &str, rest: &str) -> String {
    if rest.is_empty() {
        zh.to_string()
    } else {
        format!("{zh} · {rest}")
    }
}

/// Epic 英文标题 → 中文显示标题;已是中文、空串、认不出的英文 → `None`(界面用原文)。
pub fn display_title_zh(title: &str) -> Option<String> {
    let t = title.trim();
    if t.is_empty() || has_cjk(t) {
        return None;
    }
    let lower = t.to_ascii_lowercase();
    if let Some((_, zh)) = EXACT.iter().find(|(en, _)| *en == lower) {
        return Some((*zh).to_string());
    }
    let mut enc: Vec<&(&str, &str)> = ENCOUNTER_PREFIX.iter().collect();
    enc.sort_by_key(|(en, _)| std::cmp::Reverse(en.len()));
    for (en, zh) in enc {
        if let Some(rest) = strip_prefix_ci(t, en) {
            return Some(join(zh, drop_leading_paren(rest)));
        }
    }
    for (en, zh) in MODALITY_PREFIX {
        if let Some(rest) = strip_prefix_ci(t, en) {
            // 只有方式没有部位(`CT`)不改写:改了也只是把两个字母换成两个字母。
            if rest.is_empty() {
                return None;
            }
            return Some(join(zh, rest));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_section_names() {
        assert_eq!(
            display_title_zh("Discharge Summary Note").as_deref(),
            Some("出院小结")
        );
        assert_eq!(
            display_title_zh(" operative notes ").as_deref(),
            Some("手术记录")
        );
        assert_eq!(display_title_zh("H&P Notes").as_deref(), Some("入院记录"));
        assert_eq!(display_title_zh("Imaging").as_deref(), Some("影像"));
    }

    #[test]
    fn encounter_kind_prefix_keeps_department() {
        assert_eq!(
            display_title_zh("Office Visit Cardiology").as_deref(),
            Some("门诊 · Cardiology")
        );
        assert_eq!(
            display_title_zh("ED to Hosp-Admission (Discharged) UF 65MS").as_deref(),
            Some("急诊收入院 · UF 65MS")
        );
        assert_eq!(
            display_title_zh("Hospital Encounter").as_deref(),
            Some("住院")
        );
        assert_eq!(
            display_title_zh("Emergency Department").as_deref(),
            Some("急诊 · Department")
        );
    }

    #[test]
    fn imaging_modality_prefix() {
        assert_eq!(
            display_title_zh("CT CHEST W CONTRAST").as_deref(),
            Some("CT · CHEST W CONTRAST")
        );
        assert_eq!(
            display_title_zh("MR BRAIN WO CONTRAST").as_deref(),
            Some("磁共振 · BRAIN WO CONTRAST")
        );
        assert_eq!(
            display_title_zh("MRI LUMBAR SPINE").as_deref(),
            Some("磁共振 · LUMBAR SPINE")
        );
        assert_eq!(
            display_title_zh("ECHO TTE COMPLETE").as_deref(),
            Some("心脏超声 · TTE COMPLETE")
        );
        assert_eq!(
            display_title_zh("XR CHEST 2 VIEWS").as_deref(),
            Some("X线 · CHEST 2 VIEWS")
        );
        assert!(display_title_zh("CTA").is_none(), "词边界:CTA 不是 CT 前缀");
        assert!(
            display_title_zh("CT").is_none(),
            "只有方式没有部位,不值得改写"
        );
    }

    #[test]
    fn chinese_or_unknown_titles_pass_through() {
        assert!(display_title_zh("化验 2025-06-14").is_none());
        assert!(display_title_zh("病程记录 2025-06-03").is_none());
        assert!(display_title_zh("SURGICAL PATHOLOGY").is_none());
        assert!(display_title_zh("").is_none());
        assert!(display_title_zh("   ").is_none());
    }
}
