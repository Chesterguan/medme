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
//! - (仅对 6 位以上的兜底规则)紧跟在数字串后面(跳过同一行内的空格/制表符,但不跨行)
//!   的下一个词是化验单位或「参考」——化验值本身经常就是裸的 6 位数(比如血小板
//!   120000),不能假设「6 位以上必是证件号」;这里刻意只看数字串**自己后面**紧跟的
//!   词,而不是「整行有没有」,不然同一行里离得很远的一个证件号也会被隔壁的化验单位
//!   连累放过(fix round 2 item A)。
//!
//! 18 位证件号/手机号/座机号这三条形状规则还有一层豁免:如果匹配到的这一段前面或后面
//! 紧挨着还有 ASCII 数字,说明它只是一段更长数字串里凑巧长得像证件号/手机号的一截,
//! 不能就地掩码——不然会把长数字串切开、只掩中间那一截,两头的数字明文残留
//! (fix round 2 item B)。这种情况让它原样放过,交给后面的 6 位以上兜底规则把整段
//! 数字串当一个号码掩掉。
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

/// 化验单位标记:数字串后面紧跟着任意一个,就当化验值处理,不掩。
/// `pub(crate)`:`redact::looks_like_lab_row` 复用这份词表判断整框是不是化验行,
/// 不再另建一份重复列表(那份少了 `U/L`,两处各自漂移迟早对不上)。
pub(crate) const UNIT_TOKENS: &[&str] = &["/L", "U/L", "10^", "×10", "x10", "g/L", "%", "mmol", "umol", "μmol"];

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

/// 紧邻外侧就是另一个 ASCII 数字 → 这段只是更长数字串中间凑巧长得像证件号/手机号的
/// 一截,不能单独掩码,得留给 6 位以上兜底规则把整段一起处理。
fn embedded_in_digits(text: &str, start: usize, end: usize) -> bool {
    let before = text[..start].chars().next_back().is_some_and(|c| c.is_ascii_digit());
    let after = text[end..].chars().next().is_some_and(|c| c.is_ascii_digit());
    before || after
}

/// 数字串结束位置往后跳过同一行内的空格/制表符(不跳换行)后剩下的文本——用来看
/// 「紧跟着的下一个词是不是化验单位/参考」,不看整行。
fn next_token_after(text: &str, end: usize) -> &str {
    let rest = &text[end..];
    let skip: usize = rest
        .chars()
        .take_while(|c| *c == ' ' || *c == '\t')
        .map(|c| c.len_utf8())
        .sum();
    &rest[skip..]
}

fn followed_by_unit_or_reference(text: &str, end: usize) -> bool {
    let rest = next_token_after(text, end);
    UNIT_TOKENS.iter().any(|u| rest.starts_with(u)) || rest.starts_with("参考")
}

/// 形状类(18 位证件号/手机号/座机号):不消费邻居;外侧邻接小数点/区间号,或本身嵌在
/// 更长数字串里,都放过不掩(留给 6 位以上兜底规则处理后者)。
fn apply_shape(text: &str, re: &Regex, kind: &str, map: &mut RestoreMap) -> String {
    re.replace_all(text, |c: &regex::Captures| {
        let m = c.get(0).expect("group 0");
        if is_decimal_or_range(text, m.start(), m.end()) || embedded_in_digits(text, m.start(), m.end()) {
            m.as_str().to_string()
        } else {
            map.placeholder(kind, m.as_str())
        }
    })
    .into_owned()
}

/// URL/邮箱:形状本身已经足够特定,不需要小数/区间/嵌入豁免。
fn apply_plain(text: &str, re: &Regex, kind: &str, map: &mut RestoreMap) -> String {
    re.replace_all(text, |c: &regex::Captures| map.placeholder(kind, &c[0]))
        .into_owned()
}

/// 6 位以上兜底规则:多一层「合法日期」和「后面紧跟化验单位/参考」豁免。
fn apply_long_digits(text: &str, map: &mut RestoreMap) -> String {
    long_digits_re()
        .replace_all(text, |c: &regex::Captures| {
            let m = c.get(0).expect("group 0");
            let s = m.as_str();
            let skip = is_decimal_or_range(text, m.start(), m.end())
                || (s.len() == 8 && dates::is_compact_date(s))
                || followed_by_unit_or_reference(text, m.end());
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
    fn bare_number_before_a_unit_or_reference_token_survives() {
        let mut map = RestoreMap::default();
        let masked = apply("血小板 120000 参考 100000-300000", &mut map);
        assert!(masked.contains("120000"), "{masked}");
        assert!(masked.contains("100000-300000"), "{masked}");

        let mut map2 = RestoreMap::default();
        let masked2 = apply("血小板 120000 10^9/L", &mut map2);
        assert!(masked2.contains("120000"), "{masked2}");
    }

    #[test]
    fn unanchored_id_is_still_masked_even_when_a_lab_unit_appears_later_in_the_text() {
        // fix round 2 item A:旧版按“整行”判断,这条码后面跟的是“血红蛋白”,不是
        // 单位/参考,该掩;后面出现的 g/L 不能成为它的免罪牌。
        let mut map = RestoreMap::default();
        let masked = apply("标本 2023061512345 血红蛋白 130 g/L", &mut map);
        assert!(!masked.contains("2023061512345"), "{masked}");
        assert!(masked.contains("130 g/L"), "{masked}");
    }

    #[test]
    fn bare_id_line_is_still_masked_by_shape_rules_alone() {
        let mut map = RestoreMap::default();
        let masked = apply("2023061512345 电话 010-69156114", &mut map);
        assert!(!masked.contains("2023061512345"), "{masked}");
        assert!(!masked.contains("69156114"), "{masked}");
    }

    #[test]
    fn shape_rule_matching_inside_a_longer_digit_run_defers_to_the_long_digit_rule() {
        // fix round 2 item B:去掉 \b 之后,mobile_re/id18_re 可能在更长数字串**内部**
        // 找到一段形状对得上的子串,把它单独掩掉,两头的数字明文残留(比如
        // "2023139123456789" 曾经变成 "2023[T1]9")。直接断言占位符对应的值是整段
        // 原文——只看输出里还含不含完整原串堵不住这个漏洞,被切出来的中间一截
        // 本来就不会再包含完整原串。
        let mut map = RestoreMap::default();
        apply("样本 2023139123456789", &mut map);
        assert_eq!(map.placeholders.len(), 1, "{:?}", map.placeholders);
        assert_eq!(map.placeholders[0].1, "2023139123456789", "{:?}", map.placeholders);

        let mut map2 = RestoreMap::default();
        apply("12345678901234567890", &mut map2);
        assert_eq!(map2.placeholders.len(), 1, "{:?}", map2.placeholders);
        assert_eq!(map2.placeholders[0].1, "12345678901234567890", "{:?}", map2.placeholders);
    }
}
