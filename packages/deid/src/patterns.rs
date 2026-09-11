//! P 层:形状兜底,在 K/A 两层清完「认识」的身份信息之后,再扫一遍剩下的号码/证件/网址。
//!
//! 不用 `\b`:中文字符在 Unicode word 分类里也算 `\w`,`\b` 在「电话010-…」这类紧贴汉字
//! 的数字前根本不生效,会让整段号码漏网。也不像早期版本那样把两侧邻居字符吞进匹配本身
//! ——那样处理相邻两个数字串时,第二个会因为分隔符已经被第一个匹配吃掉而永远找不到起点。
//! 改成:先用不消费邻居的形状正则(`\d{6,}` 等)逐个找,再手工看两侧字符决定要不要跳过。
//!
//! 一个数字串只在下面几种情况被跳过、不掩码:
//! - 是小数的一部分(紧邻的外侧是 `.`,再外一层是数字);
//! - 是参考区间的一段(紧邻的外侧是 `-`/`~`,再外一层是数字);
//! - 是能解析成合法日期(1900–2099)的 8 位 yyyymmdd——放行给 `dates` 层去偏移,这里
//!   掩掉的话,日期层就看不到原始数字了;
//! - (仅对 6 位以上的兜底规则)所在整行本身带参考区间或化验单位标记——化验值/参考区间
//!   本身经常就是裸的 6 位数(比如血小板 120000),不能假设「6 位以上必是证件号」,
//!   得看行上下文。
use super::redact::RestoreMap;
use crate::dates;
use regex::Regex;
use std::sync::OnceLock;

fn id18_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\d{17}[\dXx]").expect("id18"))
}
fn mobile_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"1[3-9]\d{9}").expect("mobile"))
}
fn landline_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"0\d{2,3}-\d{7,8}").expect("landline"))
}
fn url_email_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"(?:https?://|www\.)[^\s]+|[\w.+-]+@[\w-]+\.[\w.]+").expect("url/email")
    })
}
fn long_digits_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\d{6,}").expect("long digits"))
}
fn range_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\d+(?:\.\d+)?\s*[-~]\s*\d+").expect("range"))
}

/// 化验单位标记:出现任意一个,这一行就当化验行处理(裸 6 位以上数字不掩)。
const UNIT_TOKENS: &[&str] = &["/L", "10^", "×10", "x10", "g/L", "%", "mmol", "umol", "μmol"];

/// 紧邻外侧是 `.`/`-`/`~`,且再外一层是数字 → 这段数字是小数或区间的一部分,不当证件号。
/// 只看匹配区间**外**的字符;比如座机号自己内部的那个 `-` 在匹配范围之内,不受影响。
fn is_decimal_or_range(text: &str, start: usize, end: usize) -> bool {
    let mut before = text[..start].chars().rev();
    let b1 = before.next();
    let b2 = before.next();
    let before_hit =
        matches!(b1, Some('.') | Some('-') | Some('~')) && b2.is_some_and(|c| c.is_ascii_digit());

    let mut after = text[end..].chars();
    let a1 = after.next();
    let a2 = after.next();
    let after_hit =
        matches!(a1, Some('.') | Some('-') | Some('~')) && a2.is_some_and(|c| c.is_ascii_digit());

    before_hit || after_hit
}

fn line_of(text: &str, start: usize, end: usize) -> &str {
    let line_start = text[..start].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let line_end = text[end..].find('\n').map(|i| end + i).unwrap_or(text.len());
    &text[line_start..line_end]
}

fn line_looks_like_lab_row(line: &str) -> bool {
    range_re().is_match(line) || UNIT_TOKENS.iter().any(|u| line.contains(u))
}

/// 形状类(18 位证件号/手机号/座机号):不消费邻居,只在外侧邻接小数点/区间号时放过。
fn apply_shape(text: &str, re: &Regex, kind: &str, map: &mut RestoreMap) -> String {
    re.replace_all(text, |c: &regex::Captures| {
        let m = c.get(0).expect("group 0");
        if is_decimal_or_range(text, m.start(), m.end()) {
            m.as_str().to_string()
        } else {
            map.placeholder(kind, m.as_str())
        }
    })
    .into_owned()
}

/// URL/邮箱:形状本身已经足够特定,不需要小数/区间豁免。
fn apply_plain(text: &str, re: &Regex, kind: &str, map: &mut RestoreMap) -> String {
    re.replace_all(text, |c: &regex::Captures| map.placeholder(kind, &c[0]))
        .into_owned()
}

/// 6 位以上兜底规则:多一层「合法日期」和「化验行」豁免。
fn apply_long_digits(text: &str, map: &mut RestoreMap) -> String {
    long_digits_re()
        .replace_all(text, |c: &regex::Captures| {
            let m = c.get(0).expect("group 0");
            let s = m.as_str();
            let skip = is_decimal_or_range(text, m.start(), m.end())
                || (s.len() == 8 && dates::is_compact_date(s))
                || line_looks_like_lab_row(line_of(text, m.start(), m.end()));
            if skip {
                s.to_string()
            } else {
                map.placeholder("N", s)
            }
        })
        .into_owned()
}

pub fn apply(text: &str, map: &mut RestoreMap) -> String {
    let t = apply_shape(text, id18_re(), "N", map);
    let t = apply_plain(&t, url_email_re(), "U", map);
    let t = apply_shape(&t, mobile_re(), "T", map);
    let t = apply_shape(&t, landline_re(), "T", map);
    apply_long_digits(&t, map)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::redact::RestoreMap;

    #[test]
    fn lab_row_with_reference_range_or_unit_is_not_masked_but_plain_id_line_is() {
        let mut map = RestoreMap::default();
        let masked = apply(
            "血小板 120000 参考 100000-300000 10^9/L\n门诊号 90051065",
            &mut map,
        );
        assert!(masked.contains("血小板 120000"), "化验值不该被掩:{masked}");
        assert!(masked.contains("100000-300000"), "参考区间不该被掩:{masked}");
        assert!(!masked.contains("90051065"), "没有化验行特征的裸号码仍要掩:{masked}");
    }
}
