//! 日期偏移:同一档案所有文档共用一个 ±90 天内的偏移,LLM 看到的是假绝对日期、
//! 真相对顺序;还原时减回。偏移由档案秘密派生,不落盘、随档案同步。
use chrono::{Duration, NaiveDate};
use hmac::{Hmac, KeyInit, Mac};
use regex::Regex;
use sha2::Sha256;
use std::sync::OnceLock;

/// HMAC-SHA256(secret, "date-shift") 前 4 字节 mod 181 − 90 ∈ [−90, 90]。
pub fn shift_days_from_secret(secret: &[u8]) -> i64 {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret)
        .expect("HMAC-SHA256 accepts a key of any length");
    mac.update(b"date-shift");
    let out = mac.finalize().into_bytes();
    let x = u32::from_be_bytes([out[0], out[1], out[2], out[3]]);
    (x % 181) as i64 - 90
}

// 与 parser::lib.rs 的 iso_re / cn_re 同形(那两个是私有的;两条正则字面量,不值得为此开 pub)。
fn iso_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})").expect("iso date re"))
}
fn cn_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日").expect("cn date re"))
}

/// 两侧紧邻数字 = 嵌在更长数字串里(住院号 HS-2024-08-2201),不当日期。
fn embedded_in_digits(s: &str, start: usize, end: usize) -> bool {
    let before = s[..start].chars().next_back().is_some_and(|c| c.is_ascii_digit());
    let after = s[end..].chars().next().is_some_and(|c| c.is_ascii_digit());
    before || after
}

fn shifted(y: &str, m: &str, d: &str, days: i64) -> Option<String> {
    let date = NaiveDate::from_ymd_opt(y.parse().ok()?, m.parse().ok()?, d.parse().ok()?)?;
    Some((date + Duration::days(days)).format("%Y-%m-%d").to_string())
}

fn apply(text: &str, re: &Regex, days: i64) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for caps in re.captures_iter(text) {
        let m = caps.get(0).expect("group 0");
        out.push_str(&text[last..m.start()]);
        let keep = embedded_in_digits(text, m.start(), m.end());
        match (keep, shifted(&caps[1], &caps[2], &caps[3], days)) {
            (false, Some(s)) => out.push_str(&s),
            _ => out.push_str(m.as_str()),
        }
        last = m.end();
    }
    out.push_str(&text[last..]);
    out
}

/// 所有日期(ISO 与中文两种写法)加 `days`,统一写成 `YYYY-MM-DD`。
/// 先转 ISO 写法、再转中文写法:反过来会把中文日期转出的 `YYYY-MM-DD` 又被
/// iso_re 撞上,同一个日期偏移两次。
pub fn shift_dates(text: &str, days: i64) -> String {
    let t = apply(text, iso_re(), days);
    apply(&t, cn_re(), days)
}

/// 把 `YYYY-MM-DD` 减回 `days`(LLM 输出只会是这种写法,因为它看到的就是这种)。
pub fn unshift_dates(text: &str, days: i64) -> String {
    apply(text, iso_re(), -days)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shift_days_is_deterministic_and_bounded() {
        let a = shift_days_from_secret(b"secret-a");
        assert_eq!(a, shift_days_from_secret(b"secret-a"));
        assert!((-90..=90).contains(&a));
        // 不同秘密大概率不同偏移(只要不恒等于 0 就行)
        assert!((0..50).any(|i| shift_days_from_secret(format!("s{i}").as_bytes()) != 0));
    }

    #[test]
    fn shift_and_unshift_round_trip_both_date_styles() {
        let t = "采集时间:2024-03-05 08:10 报告时间 2024年3月6日 住院号HS-2024-08-2201";
        let s = shift_dates(t, 10);
        assert!(s.contains("2024-03-15"), "{s}");
        assert!(s.contains("2024-03-16"), "{s}");
        // 嵌在长数字串里的“日期”(住院号)不动
        assert!(s.contains("HS-2024-08-2201"), "{s}");
        let back = unshift_dates(&s, 10);
        assert!(back.contains("2024-03-05") && back.contains("2024-03-06"), "{back}");
    }
}
