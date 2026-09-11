//! K 层:档案主人的姓名/证件号/手机全文精确删(粘连形态也删——精确子串,与形态无关)。
use super::redact::RestoreMap;

pub struct KnownIdentity {
    pub name: String,
    pub id_number: Option<String>,
    pub phone: Option<String>,
}

/// 把每个已知值换成一个占位符并登记到 map。空串/单字姓名不处理(避免把常见字全删)。
pub fn apply(text: &str, known: &KnownIdentity, map: &mut RestoreMap) -> String {
    let mut out = text.to_string();
    let mut items: Vec<(&str, &str)> = Vec::new();
    if known.name.chars().count() >= 2 {
        items.push((known.name.as_str(), "P"));
    }
    if let Some(id) = known.id_number.as_deref().filter(|s| !s.is_empty()) {
        items.push((id, "N"));
    }
    if let Some(ph) = known.phone.as_deref().filter(|s| !s.is_empty()) {
        items.push((ph, "T"));
    }
    for (value, kind) in items {
        if out.contains(value) {
            let ph = map.placeholder(kind, value);
            out = out.replace(value, &ph);
        }
    }
    out
}
