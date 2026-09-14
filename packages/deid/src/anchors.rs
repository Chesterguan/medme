//! A 层:锚点后的值换占位符。词表 = parser::labs::PAGE_FURNITURE 的 22 个(那边是私有 const,
//! 且语义是「挡假化验行」,这边是「掩身份」,两份各自演进,不共享)+ 本 spec 清单补的。
//! 裸的「医生/医师/患者/病人」不当锚点——它们常出现在正常临床叙述里(“医生建议复查”
//! “患者主诉发热”),不是「标签:值」的字段结构,当锚点会把后面一整句话错当成人名吃掉;
//! 复合词(送检医生/审核医生/主治医师/报告医师等)仍是可靠的标签,保留。
use super::redact::RestoreMap;
use regex::Regex;
use std::sync::OnceLock;

/// 锚点 → 占位符种类。人名类 P,号码/地址类 N/A,账号句柄类 U(微信公众号等,和 P 层的
/// URL/邮箱共用同一种占位符前缀,取值规则是自己的一套——见 `take_handle_value`,句柄
/// 形状字符集,不是 A 类那种自由文本),时间类不掩(日期由 dates 偏移;时间戳无身份信息)。
pub const ANCHORS: &[(&str, &str)] = &[
    ("姓名", "P"),
    ("名字", "P"),
    ("联系人", "P"),
    ("监护人", "P"),
    ("检验者", "P"),
    ("审核者", "P"),
    ("送检医生", "P"),
    ("申请医生", "P"),
    ("报告医生", "P"),
    ("审核医生", "P"),
    ("主治医师", "P"),
    ("报告医师", "P"),
    ("门诊号", "N"),
    ("住院号", "N"),
    ("病案号", "N"),
    ("病历号", "N"),
    ("就诊卡号", "N"),
    ("就诊卡", "N"),
    ("床号", "N"),
    ("样本号", "N"),
    ("标本号", "N"),
    ("样本编号", "N"),
    ("条码号", "N"),
    ("条码", "N"),
    ("检验号", "N"),
    ("检查号", "N"),
    ("影像号", "N"),
    ("申请单号", "N"),
    ("医保卡号", "N"),
    ("医保号", "N"),
    ("社保号", "N"),
    ("身份证号", "N"),
    ("身份证", "N"),
    ("发票号", "N"),
    ("收费单号", "N"),
    ("流水号", "N"),
    ("设备编号", "N"),
    ("仪器编号", "N"),
    ("住址", "A"),
    ("地址", "A"),
    ("家庭住址", "A"),
    ("工作单位", "A"),
    ("籍贯", "A"),
    ("民族", "A"),
    ("职业", "A"),
    ("婚姻", "A"),
    ("微信公众号", "U"),
    ("公众号", "U"),
];

/// 年龄/性别/科室是**保留字段**,锚点表里没有它们,但 OCR 常常把它们和前一个字段粘在
/// 一起、中间没有分隔符(“姓名孟丁性别男”“门诊号90051065科室儿科”)。取值时必须把
/// 这几个词当成硬性停止点,连同所有锚点词一起,不然值会把它们吃进去。
const EXTRA_STOPS: &[&str] = &["性别", "年龄", "科室"];

fn starts_with_stop_word(s: &str) -> bool {
    ANCHORS.iter().any(|(a, _)| s.starts_with(a)) || EXTRA_STOPS.iter().any(|w| s.starts_with(w))
}

fn is_cjk(c: char) -> bool {
    ('\u{4e00}'..='\u{9fa5}').contains(&c)
}

fn is_sep(c: char) -> bool {
    c.is_whitespace() || matches!(c, ':' | '：' | ',' | '，' | ';' | '；' | '、' | '|' | '。')
}

/// U 类(账号句柄,微信公众号等)允许出现在句柄里的字符——ASCII 字母/数字/`_`/`@`/`.`/`-`。
/// 句柄和自然语言叙述没有可靠的分隔符(“公众号获取检验报告”中间没有空格/标点),只能靠
/// 字符集本身当边界:叙述句是纯 CJK,句柄是纯 ASCII,两者在形状上不会重叠。
fn is_handle_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '@' | '.' | '-')
}

/// 找锚点词本身用的正则(只找词,不找值——值交给下面两个函数手工扫,因为「遇到停止词
/// 提前收尾」这种逻辑,regex crate 不支持零宽断言,没法写进一条正则里)。
fn anchor_word_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        let alts: Vec<String> = ANCHORS.iter().map(|(a, _)| regex::escape(a)).collect();
        Regex::new(&alts.join("|")).expect("anchor word re")
    })
}

/// 「XX市XX医院 / XX大学附属XX医院 / XX人民医院」整串掩成 [H]。
fn hospital_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"[\u{4e00}-\u{9fa5}]{2,12}(?:医院|卫生院|诊所|医学中心|医疗中心)(?:[\u{4e00}-\u{9fa5}]{0,4}(?:分院|院区))?").expect("hospital re"))
}

fn kind_of(anchor: &str) -> &'static str {
    ANCHORS
        .iter()
        .find(|(a, _)| *a == anchor)
        .map(|(_, k)| *k)
        .unwrap_or("N")
}

/// P 类(人名):2~6 个中文字符(部分少数民族/复姓名字有 5~6 字);一碰到任意锚点词或
/// 性别/年龄/科室 开头,立刻收尾——即使中间没有分隔符。
fn take_name_value(rest: &str) -> Option<&str> {
    let mut end = 0;
    let mut count = 0;
    for c in rest.chars() {
        if count >= 6 || !is_cjk(c) || starts_with_stop_word(&rest[end..]) {
            break;
        }
        end += c.len_utf8();
        count += 1;
    }
    (count >= 2).then(|| &rest[..end])
}

/// N/A 类(号码/地址):不设字符数上限,一直取到下一个空白/标点分隔符或下一个锚点词为止
/// ——18 位身份证号、16 位住院号都得整段吃掉,不能像人名那样卡字数。
/// `stop_at_digit_to_cjk` 仅用于 N 类:值一旦以数字开头,后面紧跟的中文字符就不再算进
/// 值里——不然会把没有分隔符、紧贴在号码后面的叙述文字(“门诊号90051065病区三”里的
/// “病区三”)一起吞掉。A 类(住址/民族/职业/婚姻等)本身就是自由文本,没有这种数字/
/// 中文的形状边界可用,继续保持不设上限(fix round 2 item D:已知的残留问题,不在本轮修)。
fn take_free_value(rest: &str, stop_at_digit_to_cjk: bool) -> Option<&str> {
    if rest.starts_with('[') {
        return None; // 已经是占位符(K 层删过),原样放过
    }
    let starts_with_digit =
        stop_at_digit_to_cjk && rest.chars().next().is_some_and(|c| c.is_ascii_digit());
    let mut end = 0;
    for c in rest.chars() {
        if is_sep(c) || starts_with_stop_word(&rest[end..]) || (starts_with_digit && is_cjk(c)) {
            break;
        }
        end += c.len_utf8();
    }
    (end > 0).then(|| &rest[..end])
}

/// U 类(账号句柄):不像 A/N 那样"什么都行、直到分隔符为止"——句柄后面紧跟的往往是
/// 没有分隔符的中文叙述(“关注公众号获取报告”),用 `take_free_value` 会把整句话吃掉。
/// 改成正形状匹配:第一个字符就必须是句柄字符,否则这个锚点根本不取值(“不点火”,
/// 原文原样放过);取到的字符也全部限定在句柄字符集里,天然在遇到 CJK 叙述、全角标点
/// 时收尾,不需要额外的停止词表。
fn take_handle_value(rest: &str) -> Option<&str> {
    if !rest.starts_with(is_handle_char) {
        return None;
    }
    let mut end = 0;
    for c in rest.chars() {
        if !is_handle_char(c) {
            break;
        }
        end += c.len_utf8();
    }
    Some(&rest[..end])
}

pub fn apply(text: &str, map: &mut RestoreMap) -> String {
    let t = hospital_re()
        .replace_all(text, |c: &regex::Captures| map.placeholder("H", &c[0]))
        .into_owned();

    let mut out = String::with_capacity(t.len());
    let mut last = 0;
    for m in anchor_word_re().find_iter(&t) {
        if m.start() < last {
            continue; // 防御性:被上一次取值消费掉的区间不会再产生新匹配的起点
        }
        out.push_str(&t[last..m.start()]);
        let anchor = m.as_str();
        out.push_str(anchor);
        let kind = kind_of(anchor);

        let mut pos = m.end();
        let skip: usize = t[pos..]
            .chars()
            .take_while(|c| *c == ':' || *c == '：' || c.is_whitespace())
            .map(|c| c.len_utf8())
            .sum();
        out.push_str(&t[pos..pos + skip]);
        pos += skip;

        let rest = &t[pos..];
        let value = match kind {
            "P" => take_name_value(rest),
            "U" => take_handle_value(rest),
            _ => take_free_value(rest, kind == "N"),
        };
        if let Some(v) = value {
            out.push_str(&map.placeholder(kind, v));
            pos += v.len();
        }
        last = pos;
    }
    out.push_str(&t[last..]);
    out
}
