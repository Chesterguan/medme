//! A 层:锚点后的值换占位符。词表 = parser::labs::PAGE_FURNITURE 的 22 个(那边是私有 const,
//! 且语义是「挡假化验行」,这边是「掩身份」,两份各自演进,不共享)+ 本 spec 清单补的。
use super::redact::RestoreMap;
use regex::Regex;
use std::sync::OnceLock;

/// 锚点 → 占位符种类。人名类 P,号码类 N,时间类不掩(日期由 dates 偏移;时间戳无身份信息)。
pub const ANCHORS: &[(&str, &str)] = &[
    ("姓名", "P"), ("名字", "P"), ("患者", "P"), ("病人", "P"), ("联系人", "P"), ("监护人", "P"),
    ("检验者", "P"), ("审核者", "P"), ("送检医生", "P"), ("申请医生", "P"), ("报告医生", "P"),
    ("审核医生", "P"), ("主治医师", "P"), ("报告医师", "P"), ("医师", "P"), ("医生", "P"),
    ("门诊号", "N"), ("住院号", "N"), ("病案号", "N"), ("病历号", "N"), ("就诊卡号", "N"), ("就诊卡", "N"),
    ("床号", "N"), ("样本号", "N"), ("标本号", "N"), ("样本编号", "N"), ("条码号", "N"), ("条码", "N"),
    ("检验号", "N"), ("检查号", "N"), ("影像号", "N"), ("申请单号", "N"), ("医保卡号", "N"), ("医保号", "N"),
    ("社保号", "N"), ("身份证号", "N"), ("身份证", "N"), ("发票号", "N"), ("收费单号", "N"), ("流水号", "N"),
    ("设备编号", "N"), ("仪器编号", "N"), ("住址", "A"), ("地址", "A"), ("家庭住址", "A"), ("工作单位", "A"),
    ("籍贯", "A"), ("民族", "A"), ("职业", "A"), ("婚姻", "A"),
];

/// 锚点后:可选冒号/空白,然后取到下一个空白/分隔符或 12 个字符为止。
fn anchor_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        let alts: Vec<String> = ANCHORS.iter().map(|(a, _)| regex::escape(a)).collect();
        Regex::new(&format!(
            r"({})[:：]?\s*([^\s:：,，;；、|]{{1,12}})",
            alts.join("|")
        ))
        .expect("anchor re")
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

/// 年龄/性别是**保留项**:锚点表里没有它们,所以「姓名孟丁性别男」在 K 层删掉名字后,
/// 这里不会再把「性别男」当成锚点值吃掉。
pub fn apply(text: &str, map: &mut RestoreMap) -> String {
    let t = hospital_re().replace_all(text, |c: &regex::Captures| map.placeholder("H", &c[0])).into_owned();
    anchor_re()
        .replace_all(&t, |c: &regex::Captures| {
            let anchor = &c[1];
            let value = &c[2];
            // 值本身已经是占位符(K 层删过)→ 原样
            if value.starts_with('[') {
                return c[0].to_string();
            }
            let ph = map.placeholder(kind_of(anchor), value);
            c[0].replacen(value, &ph, 1)
        })
        .into_owned()
}
