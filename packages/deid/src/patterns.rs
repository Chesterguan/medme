//! P 层:形状兜底。检验值/参考区间不会是 18 位、11 位或 6 位以上连续数字,所以误伤面小。
use super::redact::RestoreMap;
use regex::Regex;
use std::sync::OnceLock;

fn res() -> &'static [(Regex, &'static str)] {
    static R: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    R.get_or_init(|| {
        vec![
            (Regex::new(r"\b\d{17}[\dXx]\b").expect("id18"), "N"),
            (Regex::new(r"(?:https?://|www\.)[^\s]+|[\w.+-]+@[\w-]+\.[\w.]+").expect("url/email"), "U"),
            (Regex::new(r"\b1[3-9]\d{9}\b").expect("mobile"), "T"),
            (Regex::new(r"\b0\d{2,3}-\d{7,8}\b").expect("landline"), "T"),
            // 6 位以上连续数字(条码/样本号/病历号);前后不能是小数点或 `-`/`~`(那是区间)
            (Regex::new(r"(?:^|[^\d.\-~])(\d{6,})(?:$|[^\d.\-~])").expect("long digits"), "N"),
        ]
    })
}

pub fn apply(text: &str, map: &mut RestoreMap) -> String {
    let mut out = text.to_string();
    for (re, kind) in res() {
        out = re
            .replace_all(&out, |c: &regex::Captures| {
                // long-digits 那条有捕获组 1;其余整段
                match c.get(1) {
                    Some(m) => c[0].replacen(m.as_str(), &map.placeholder(kind, m.as_str()), 1),
                    None => map.placeholder(kind, &c[0]),
                }
            })
            .into_owned();
    }
    out
}
