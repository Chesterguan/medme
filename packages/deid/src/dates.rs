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
fn compact_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\d{8}").expect("compact date re"))
}

/// `s` 是不是一个合法的 yyyymmdd(年份限定 1900–2099,避免把普通 8 位号码/条码误判成
/// 日期)。P 层用这个放行——放行之后交给这里偏移,不然会先被 P 层的长数字串规则掩成占位符。
pub(crate) fn is_compact_date(s: &str) -> bool {
    if s.len() != 8 {
        return false;
    }
    let y: i32 = match s[0..4].parse() {
        Ok(v) => v,
        Err(_) => return false,
    };
    let m: u32 = match s[4..6].parse() {
        Ok(v) => v,
        Err(_) => return false,
    };
    let d: u32 = match s[6..8].parse() {
        Ok(v) => v,
        Err(_) => return false,
    };
    (1900..=2099).contains(&y) && NaiveDate::from_ymd_opt(y, m, d).is_some()
}

fn shifted_compact(s: &str, days: i64) -> Option<String> {
    if !is_compact_date(s) {
        return None;
    }
    let date = NaiveDate::from_ymd_opt(s[0..4].parse().ok()?, s[4..6].parse().ok()?, s[6..8].parse().ok()?)?;
    Some((date + Duration::days(days)).format("%Y%m%d").to_string())
}

fn apply_compact(text: &str, days: i64) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for m in compact_re().find_iter(text) {
        out.push_str(&text[last..m.start()]);
        let keep = embedded_in_digits(text, m.start(), m.end());
        match (keep, shifted_compact(m.as_str(), days)) {
            (false, Some(s)) => out.push_str(&s),
            _ => out.push_str(m.as_str()),
        }
        last = m.end();
    }
    out.push_str(&text[last..]);
    out
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

/// 所有日期(ISO、中文、紧凑 yyyymmdd 三种写法)加 `days`。ISO/中文统一写成
/// `YYYY-MM-DD`;紧凑写法保持紧凑(`采集时间20240305` → `采集时间20240312`),因为它常常
/// 是本来就没有分隔符的字段,不该在偏移后凭空长出横线。
/// 先转 ISO 写法、再转中文写法:反过来会把中文日期转出的 `YYYY-MM-DD` 又被
/// iso_re 撞上,同一个日期偏移两次。紧凑写法最后处理——它形状最宽松(纯 8 位数字),
/// 放前面会把还没转换的 ISO/中文日期里的数字子串误当紧凑日期抢先吃掉。
pub fn shift_dates(text: &str, days: i64) -> String {
    let t = apply(text, iso_re(), days);
    let t = apply(&t, cn_re(), days);
    apply_compact(&t, days)
}

/// 把 `YYYY-MM-DD` 和紧凑 `yyyymmdd` 都减回 `days`(LLM 输出要么是 ISO 写法——因为它看到
/// 的就是这种——要么是没被偏移逻辑碰过、原样透传回来的紧凑写法)。
pub fn unshift_dates(text: &str, days: i64) -> String {
    let t = apply(text, iso_re(), -days);
    apply_compact(&t, -days)
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

    #[test]
    fn compact_yyyymmdd_date_shifts_and_restores() {
        let s = shift_dates("采集时间20240305", 7);
        assert!(s.contains("20240312"), "{s}");
        let back = unshift_dates(&s, 7);
        assert_eq!(back, "采集时间20240305");
    }

    #[test]
    fn compact_date_embedded_in_longer_digit_run_is_untouched() {
        // 前 8 位恰好能解析成合法日期,但后面还跟着数字,说明这是号码的一部分,不是日期。
        let t = "住院号2024030512345";
        assert_eq!(shift_dates(t, 7), t);
    }
}
