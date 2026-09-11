//! A 层:锚点后的值换占位符。词表 = parser::labs::PAGE_FURNITURE 的 22 个(那边是私有 const,
//! 且语义是「挡假化验行」,这边是「掩身份」,两份各自演进,不共享)+ 本 spec 清单补的。
//! 裸的「医生/医师/患者/病人」不当锚点——它们常出现在正常临床叙述里(“医生建议复查”
//! “患者主诉发热”),不是「标签:值」的字段结构,当锚点会把后面一整句话错当成人名吃掉;
//! 复合词(送检医生/审核医生/主治医师/报告医师等)仍是可靠的标签,保留。
use super::redact::RestoreMap;
use regex::Regex;
use std::sync::OnceLock;

/// 锚点 → 占位符种类。人名类 P,号码/地址类 N/A,时间类不掩(日期由 dates 偏移;时间戳无身份信息)。
pub const ANCHORS: &[(&str, &str)] = &[
    ("姓名", "P"), ("名字", "P"), ("联系人", "P"), ("监护人", "P"),
    ("检验者", "P"), ("审核者", "P"), ("送检医生", "P"), ("申请医生", "P"), ("报告医生", "P"),
    ("审核医生", "P"), ("主治医师", "P"), ("报告医师", "P"),
    ("门诊号", "N"), ("住院号", "N"), ("病案号", "N"), ("病历号", "N"), ("就诊卡号", "N"), ("就诊卡", "N"),
    ("床号", "N"), ("样本号", "N"), ("标本号", "N"), ("样本编号", "N"), ("条码号", "N"), ("条码", "N"),
    ("检验号", "N"), ("检查号", "N"), ("影像号", "N"), ("申请单号", "N"), ("医保卡号", "N"), ("医保号", "N"),
    ("社保号", "N"), ("身份证号", "N"), ("身份证", "N"), ("发票号", "N"), ("收费单号", "N"), ("流水号", "N"),
    ("设备编号", "N"), ("仪器编号", "N"), ("住址", "A"), ("地址", "A"), ("家庭住址", "A"), ("工作单位", "A"),
    ("籍贯", "A"), ("民族", "A"), ("职业", "A"), ("婚姻", "A"),
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
    c.is_whitespace() || matches!(c, ':' | '：' | ',' | '，' | ';' | '；' | '、' | '|')
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
    ANCHORS.iter().find(|(a, _)| *a == anchor).map(|(_, k)| *k).unwrap_or("N")
}

/// P 类(人名):2~4 个中文字符;一碰到任意锚点词或 性别/年龄/科室 开头,立刻收尾——
/// 即使中间没有分隔符。
fn take_name_value(rest: &str) -> Option<&str> {
    let mut end = 0;
    let mut count = 0;
    for c in rest.chars() {
        if count >= 4 || !is_cjk(c) || starts_with_stop_word(&rest[end..]) {
            break;
        }
        end += c.len_utf8();
        count += 1;
    }
    (count >= 2).then(|| &rest[..end])
}

/// N/A 类(号码/地址):不设字符数上限,一直取到下一个空白/标点分隔符或下一个锚点词为止
/// ——18 位身份证号、16 位住院号都得整段吃掉,不能像人名那样卡字数。
fn take_id_value(rest: &str) -> Option<&str> {
    if rest.starts_with('[') {
        return None; // 已经是占位符(K 层删过),原样放过
    }
    let mut end = 0;
    for c in rest.chars() {
        if is_sep(c) || starts_with_stop_word(&rest[end..]) {
            break;
        }
        end += c.len_utf8();
    }
    (end > 0).then(|| &rest[..end])
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
        let value = if kind == "P" {
            take_name_value(rest)
        } else {
            take_id_value(rest)
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
