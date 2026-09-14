//! schema v1(spec §3)+ 逐字校验(spec §4)。
//! spec 硬规矩「字段全是原文逐字」适用于 schema v1 的每一个字符串字段,不止 labs 的五个——
//! doc_date/impression/notes、LabItem.flag、MedItem.dose/freq/route、DiagnosisItem.icd 同样要查(2026-09-11 修订轮 1)。
use crate::DeidError;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct LabItem {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub unit: String,
    #[serde(default)]
    pub ref_low: String,
    #[serde(default)]
    pub ref_high: String,
    #[serde(default)]
    pub flag: String,
    #[serde(default)]
    pub unverified: bool,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct MedItem {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub dose: String,
    #[serde(default)]
    pub freq: String,
    #[serde(default)]
    pub route: String,
    #[serde(default)]
    pub unverified: bool,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct DiagnosisItem {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub icd: String,
    #[serde(default)]
    pub unverified: bool,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct Extraction {
    #[serde(default)]
    pub doc_type: String,
    #[serde(default)]
    pub doc_date: String,
    #[serde(default)]
    pub labs: Vec<LabItem>,
    #[serde(default)]
    pub meds: Vec<MedItem>,
    #[serde(default)]
    pub diagnoses: Vec<DiagnosisItem>,
    #[serde(default)]
    pub impression: String,
    #[serde(default)]
    pub notes: String,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mode {
    Text,
    Image,
}

pub struct Verified {
    pub extraction: Extraction,
    pub rejected: usize,
    pub unverified: usize,
    pub unverified_fields: Vec<String>,
}

/// LLM 偶尔包 ```json 围栏;剥掉再解析。其它形状的错误如实返回。
pub fn parse_extraction(llm_json: &str) -> Result<Extraction, DeidError> {
    let s = llm_json.trim();
    let s = s
        .strip_prefix("```json")
        .or_else(|| s.strip_prefix("```"))
        .unwrap_or(s);
    let s = s.strip_suffix("```").unwrap_or(s).trim();
    Ok(serde_json::from_str(s)?)
}

/// 字段属于数值(化验的 value/ref_low/ref_high)、名字(化验/药品的 name)还是
/// 普通文本(其余所有字段)。三类在图片档下的可接受等价不同,见 [`field_ok`]。
#[derive(Clone, Copy)]
enum FieldKind {
    Numeric,
    Name,
    Text,
}

/// 只把"数字,数字"里的逗号变句号(两侧都得是数字才转),不整体去空白。
/// 若整体去空白,跨行相邻的两个数字会被拼接成一个更长的假数字,图片档就可能对着拼接结果误判为"验真"。
fn comma_between_digits_to_dot(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    for (i, &c) in chars.iter().enumerate() {
        let prev_digit = i > 0 && chars[i - 1].is_ascii_digit();
        let next_digit = i + 1 < chars.len() && chars[i + 1].is_ascii_digit();
        out.push(if c == ',' && prev_digit && next_digit {
            '.'
        } else {
            c
        });
    }
    out
}

/// 去掉所有空白;只用于文本字段的图片档比对——文本字段跨行拼接不构成"假验真"风险。
fn strip_ws(s: &str) -> String {
    s.split_whitespace().collect()
}

// ---------------------------------------------------------------------------
// 图片档容错(Task 9b)。**只作用于 `Mode::Image`**,文本档一个字都没放宽。
//
// 为什么放宽:图片档里模型看的是原件,本地 OCR 文本只是旁证。683 份实测下来
// 35.8% 的化验行过不了逐字子串,而这批行单独对真值比是 95.6% 正确——对不上的
// 是旁证,不是模型。逐字校验在这里量的是本地 OCR 的错字率,不是幻觉率。
//
// 放宽到哪为止:
//   * 数值一律要求**解析后相等**,永不"接近"(5.6 ≠ 5.61,一位小数点之差在
//     临床上可以是两个完全不同的结论);
//   * 名字放到编辑距离 1,但**两边都能被词典解析成不同术语**时立刻收回
//     ——「红细胞计数」和「白细胞计数」正好差一个字,那不是误读,是另一个指标。
// ---------------------------------------------------------------------------

/// 单字符折叠:全角→半角、小写、把常见 OCR 混淆并进同一个代表字符。
/// 空白原样留着(去空白由调用方决定,数值那条路**必须**先按空白切词,
/// 否则 `115 150` 会被拼成 `115150` 而误判为验真)。
fn fold_char(c: char) -> char {
    let c = match c {
        '\u{3000}' => ' ',
        // 全角 ！..～ → ASCII 0x21..0x7E
        '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
        _ => c,
    };
    let c = c.to_lowercase().next().unwrap_or(c);
    match c {
        'o' => '0',
        // ↓ 和 L 归一类:化验单上「偏低」既写 ↓ 也写 L,而 l/I/| 与 1 本就难分
        'l' | 'i' | '|' | '↓' => '1',
        's' => '5',
        'b' => '8',
        ',' => '.',
        '−' | '—' | '–' => '-',
        '×' | '✕' => 'x',
        // ↑ 和 H:同上,「偏高」的两种写法
        '↑' => 'h',
        other => other,
    }
}

/// 折叠 + 去空白。文本字段用。
fn fold(s: &str) -> String {
    s.chars()
        .map(fold_char)
        .filter(|c| !c.is_whitespace())
        .collect()
}

/// 把一个字段解析成数。折叠后必须**原串里本来就有阿拉伯数字**才算数——
/// 否则 `SOS` 会被折成 `505`,凭空变出一个能对上的数值。
fn parse_num(s: &str) -> Option<f64> {
    if !s.chars().any(|c| c.is_ascii_digit()) {
        return None;
    }
    fold(s)
        .trim_start_matches('+')
        .parse::<f64>()
        .ok()
        .filter(|v| v.is_finite())
}

/// 原文里出现过的数值。**先按空白切词**再在词内找数字串:空白分开的两个数字
/// 不许拼成一个更长的数(旧注释里的跨行拼接误判,同一个坑)。
fn source_numbers(text: &str) -> Vec<f64> {
    let mut out = Vec::new();
    for tok in text.split_whitespace() {
        let (mut run, mut had_digit) = (String::new(), false);
        // 末尾补一个哨兵字符,让最后一段数字也走一次收尾
        for c in tok.chars().chain(std::iter::once('\u{0}')) {
            let f = fold_char(c);
            if f.is_ascii_digit() || f == '.' {
                run.push(f);
                had_digit |= c.is_ascii_digit();
            } else {
                if had_digit {
                    if let Some(n) = run
                        .trim_matches('.')
                        .parse::<f64>()
                        .ok()
                        .filter(|v: &f64| v.is_finite())
                    {
                        out.push(n);
                    }
                }
                run.clear();
                had_digit = false;
            }
        }
    }
    out
}

/// 编辑距离 ≤ 1(含相等)。只要判「≤1」,不需要整张 DP 表:长度差 >1 直接否,
/// 否则一次扫描,第二处不同就返回 false。
fn within_one(a: &[char], b: &[char]) -> bool {
    if a.len().abs_diff(b.len()) > 1 {
        return false;
    }
    let (s, t) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    let (mut i, mut j, mut diff) = (0usize, 0usize, 0usize);
    while i < s.len() && j < t.len() {
        if s[i] == t[j] {
            i += 1;
            j += 1;
            continue;
        }
        diff += 1;
        if diff > 1 {
            return false;
        }
        if s.len() == t.len() {
            i += 1; // 替换
        }
        j += 1; // 替换或删除(长的那边多吃一个)
    }
    diff + (t.len() - j) <= 1
}

/// 名字的模糊下限,与 `terminology` 的 `FUZZY_MIN_LEN` 同值同理由:三字及以下
/// 不做模糊(钾/钠/氯、牛奶/小麦这类,字太少,分不开"同一个词的误读"和
/// "同一张单子上的另一项")。
const NAME_FUZZY_MIN_LEN: usize = 4;

/// 每份文档算一次的原文索引。`keys` 是懒的:只有名字连折叠比对和模糊都没过
/// 的时候才会去建,建一次全文档共用(`terminology::resolve` 未命中时要扫词典,
/// 不值得每个字段重来一遍)。
struct Src<'a> {
    text: &'a str,
    num: String,
    ws: String,
    folded: String,
    /// 模糊比对的落点:每一行 + 行内按空白切出的每个词,各自折叠。
    /// **只拿它们的前缀比**,不拿任意内部窗口——「红细胞计数」与「细胞计数」
    /// 也差一个字,可原文那一段是「白细胞计数」,放行就是把值安到了别的指标上。
    /// 留着"整行"这一项是因为化验名常在行首、而 OCR 会把名字断成两段
    /// (「白细胞 计数」),按词切就拼不回来了。
    folded_cands: Vec<Vec<char>>,
    numbers: Vec<f64>,
    keys: std::cell::OnceCell<std::collections::HashSet<String>>,
}

impl<'a> Src<'a> {
    fn new(text: &'a str) -> Src<'a> {
        Src {
            text,
            num: comma_between_digits_to_dot(text),
            ws: strip_ws(text),
            folded: fold(text),
            folded_cands: text
                .lines()
                .flat_map(|l| std::iter::once(l).chain(l.split_whitespace()))
                .map(|s| fold(s).chars().collect())
                .collect(),
            numbers: source_numbers(text),
            keys: std::cell::OnceCell::new(),
        }
    }

    /// 原文里能被词典解析出来的术语 key 全集(整行 + 按空白切出的词)。
    fn keys(&self) -> &std::collections::HashSet<String> {
        self.keys.get_or_init(|| {
            let mut set = std::collections::HashSet::new();
            for line in self.text.lines() {
                for cand in std::iter::once(line).chain(line.split_whitespace()) {
                    if let Some(m) = terminology::resolve(cand, None) {
                        set.insert(m.key);
                    }
                }
            }
            set
        })
    }

    /// 名字:折叠后与原文某个落点的**前缀**相差 ≤1 个字。
    /// **护栏**:那段前缀本身能被词典解析成另一个术语时不放行(红细胞/白细胞)。
    fn name_near_miss(&self, folded_value: &str, value_key: Option<&str>) -> bool {
        let v: Vec<char> = folded_value.chars().collect();
        if v.len() < NAME_FUZZY_MIN_LEN {
            return false;
        }
        for cand in &self.folded_cands {
            for w in v.len().saturating_sub(1)..=v.len() + 1 {
                if w == 0 || w > cand.len() || !within_one(&v, &cand[..w]) {
                    continue;
                }
                let s: String = cand[..w].iter().collect();
                match (terminology::resolve(&s, None), value_key) {
                    // 两边都是词典里的真术语,而且不是同一个 → 是邻项,不是误读
                    (Some(m), Some(k)) if m.key != k => continue,
                    _ => return true,
                }
            }
        }
        false
    }
}

/// 文本档:逐字子串,对所有字段一视同仁。
///
/// 图片档:先走原来的逐字路(数值只做 `,`→`.`,文本去空白),没过再按字段类别
/// 试容错等价——数值要解析后**相等**,名字额外给编辑距离 1 与「词典解析到同一
/// 术语」两条,其余文本只做字符折叠。空字段视为通过——LLM 没提取到不算错。
fn field_ok(value: &str, src: &Src, mode: Mode, kind: FieldKind) -> bool {
    if value.is_empty() {
        return true;
    }
    if let Mode::Text = mode {
        return src.text.contains(value);
    }
    match kind {
        FieldKind::Numeric => {
            if src.num.contains(&comma_between_digits_to_dot(value)) {
                return true;
            }
            match parse_num(value) {
                // 相等,不是接近:`==` 是这条规则的全部内容,别换成 eps 比较
                Some(n) => src.numbers.contains(&n),
                // 不是数(阴性、+、未见异常……)就按普通文本比
                None => src.folded.contains(&fold(value)),
            }
        }
        FieldKind::Text => src.ws.contains(&strip_ws(value)) || src.folded.contains(&fold(value)),
        FieldKind::Name => {
            if src.ws.contains(&strip_ws(value)) {
                return true;
            }
            let folded = fold(value);
            if src.folded.contains(&folded) {
                return true;
            }
            let key = terminology::resolve(value, None).map(|m| m.key);
            // 原文印缩写、模型输出规范名(WBC ↔ 白细胞计数):编辑距离很远,同一个指标
            if key.as_deref().is_some_and(|k| src.keys().contains(k)) {
                return true;
            }
            src.name_near_miss(&folded, key.as_deref())
        }
    }
}

/// 顶层标量字段(doc_date/impression/notes)校验:文本档不verbatim就清空并计入 rejected;
/// 图片档保留原值,把字段名记进 unverified_fields 并计入 unverified。
fn check_top_field(
    name: &'static str,
    field: &mut String,
    ok: bool,
    mode: Mode,
    rejected: &mut usize,
    unverified: &mut usize,
    unverified_fields: &mut Vec<String>,
) {
    if ok {
        return;
    }
    match mode {
        Mode::Text => {
            field.clear();
            *rejected += 1;
        }
        Mode::Image => {
            unverified_fields.push(name.to_string());
            *unverified += 1;
        }
    }
}

pub fn verify(mut e: Extraction, source_text: &str, mode: Mode) -> Verified {
    let src = Src::new(source_text);
    let (mut rejected, mut unverified) = (0usize, 0usize);
    let mut unverified_fields = Vec::new();

    let ok = field_ok(&e.doc_date, &src, mode, FieldKind::Text);
    check_top_field(
        "doc_date",
        &mut e.doc_date,
        ok,
        mode,
        &mut rejected,
        &mut unverified,
        &mut unverified_fields,
    );
    let ok = field_ok(&e.impression, &src, mode, FieldKind::Text);
    check_top_field(
        "impression",
        &mut e.impression,
        ok,
        mode,
        &mut rejected,
        &mut unverified,
        &mut unverified_fields,
    );
    let ok = field_ok(&e.notes, &src, mode, FieldKind::Text);
    check_top_field(
        "notes",
        &mut e.notes,
        ok,
        mode,
        &mut rejected,
        &mut unverified,
        &mut unverified_fields,
    );

    let mut keep = |ok: bool, flag: &mut bool| -> bool {
        match (mode, ok) {
            (_, true) => true,
            (Mode::Text, false) => {
                rejected += 1;
                false
            }
            (Mode::Image, false) => {
                *flag = true;
                unverified += 1;
                true
            }
        }
    };
    e.labs.retain_mut(|l| {
        let ok = field_ok(&l.name, &src, mode, FieldKind::Name)
            && field_ok(&l.value, &src, mode, FieldKind::Numeric)
            && field_ok(&l.unit, &src, mode, FieldKind::Text)
            && field_ok(&l.ref_low, &src, mode, FieldKind::Numeric)
            && field_ok(&l.ref_high, &src, mode, FieldKind::Numeric)
            && field_ok(&l.flag, &src, mode, FieldKind::Text);
        keep(ok, &mut l.unverified)
    });
    e.meds.retain_mut(|m| {
        let ok = field_ok(&m.name, &src, mode, FieldKind::Name)
            && field_ok(&m.dose, &src, mode, FieldKind::Text)
            && field_ok(&m.freq, &src, mode, FieldKind::Text)
            && field_ok(&m.route, &src, mode, FieldKind::Text);
        keep(ok, &mut m.unverified)
    });
    e.diagnoses.retain_mut(|d| {
        let ok = field_ok(&d.text, &src, mode, FieldKind::Text)
            && field_ok(&d.icd, &src, mode, FieldKind::Text);
        keep(ok, &mut d.unverified)
    });

    Verified {
        extraction: e,
        rejected,
        unverified,
        unverified_fields,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const SRC: &str =
        "白细胞计数 WBC 5.6 10^9/L 4.0-10.0\n血红蛋白 HGB 13,5 g/L 115-150\n诊断:2型糖尿病 E11.9";

    fn e() -> Extraction {
        Extraction {
            labs: vec![
                LabItem {
                    name: "白细胞计数".into(),
                    value: "5.6".into(),
                    unit: "10^9/L".into(),
                    ref_low: "4.0".into(),
                    ref_high: "10.0".into(),
                    ..Default::default()
                },
                LabItem {
                    name: "血红蛋白".into(),
                    value: "13.5".into(),
                    unit: "g/L".into(),
                    ref_low: "115".into(),
                    ref_high: "150".into(),
                    ..Default::default()
                },
                LabItem {
                    name: "血小板".into(),
                    value: "250".into(),
                    ..Default::default()
                },
            ],
            diagnoses: vec![DiagnosisItem {
                text: "2型糖尿病".into(),
                icd: "E11.9".into(),
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    #[test]
    fn text_mode_drops_anything_not_verbatim() {
        let v = verify(e(), SRC, Mode::Text);
        // 13.5 原文是 13,5 → 文本档严格,丢;血小板不在原文,丢
        assert_eq!(v.extraction.labs.len(), 1);
        assert_eq!(v.rejected, 2);
        assert_eq!(v.unverified, 0);
        assert_eq!(v.extraction.diagnoses.len(), 1);
    }

    #[test]
    fn image_mode_keeps_but_flags() {
        let v = verify(e(), SRC, Mode::Image);
        assert_eq!(v.extraction.labs.len(), 3);
        assert!(!v.extraction.labs[0].unverified);
        assert!(!v.extraction.labs[1].unverified, "13,5 归一后等于 13.5");
        assert!(v.extraction.labs[2].unverified);
        assert_eq!(v.unverified, 1);
        assert_eq!(v.rejected, 0);
    }

    #[test]
    fn parse_tolerates_code_fence() {
        let j = "```json\n{\"doc_type\":\"lab\",\"labs\":[]}\n```";
        assert_eq!(parse_extraction(j).unwrap().doc_type, "lab");
    }

    #[test]
    fn parse_malformed_json_is_deid_error() {
        assert!(matches!(
            parse_extraction("not json"),
            Err(DeidError::Json(_))
        ));
    }

    #[test]
    fn empty_fields_are_allowed() {
        let ex = Extraction::default();
        let v = verify(ex, SRC, Mode::Text);
        assert_eq!(v.rejected, 0);
        assert_eq!(v.unverified, 0);
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let j = r#"{"doc_type":"lab","weird_extra_field":123,"labs":[]}"#;
        assert_eq!(parse_extraction(j).unwrap().doc_type, "lab");
    }

    // --- round 1 fixes: every string field must be verified, not just labs' five ---

    #[test]
    fn hallucinated_doc_date_is_dropped_in_text_mode() {
        let ex = Extraction {
            doc_date: "2099-01-01".into(),
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Text);
        assert_eq!(v.extraction.doc_date, "");
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn hallucinated_doc_date_is_flagged_in_image_mode() {
        let ex = Extraction {
            doc_date: "2099-01-01".into(),
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Image);
        assert_eq!(v.extraction.doc_date, "2099-01-01", "图片档保留原值");
        assert!(v.unverified_fields.contains(&"doc_date".to_string()));
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn hallucinated_impression_and_notes_are_dropped_in_text_mode() {
        let ex = Extraction {
            impression: "杜撰的印象".into(),
            notes: "杜撰的备注".into(),
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Text);
        assert_eq!(v.extraction.impression, "");
        assert_eq!(v.extraction.notes, "");
        assert_eq!(v.rejected, 2);
    }

    #[test]
    fn fabricated_lab_flag_drops_item_in_text_mode() {
        let ex = Extraction {
            labs: vec![LabItem {
                name: "白细胞计数".into(),
                value: "5.6".into(),
                unit: "10^9/L".into(),
                ref_low: "4.0".into(),
                ref_high: "10.0".into(),
                flag: "↑".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Text);
        assert_eq!(v.extraction.labs.len(), 0, "SRC 里没有 ↑,整条应丢");
        assert_eq!(v.rejected, 1);
    }

    const MED_SRC: &str = "阿司匹林肠溶片 100mg 每日一次 口服";

    #[test]
    fn med_with_hallucinated_dose_is_dropped_in_text_mode() {
        let ex = Extraction {
            meds: vec![MedItem {
                name: "阿司匹林肠溶片".into(),
                dose: "500mg".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, MED_SRC, Mode::Text);
        assert_eq!(v.extraction.meds.len(), 0);
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn med_with_hallucinated_dose_is_flagged_per_item_in_image_mode() {
        let ex = Extraction {
            meds: vec![MedItem {
                name: "阿司匹林肠溶片".into(),
                dose: "500mg".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, MED_SRC, Mode::Image);
        assert_eq!(v.extraction.meds.len(), 1);
        assert!(v.extraction.meds[0].unverified);
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn diagnosis_with_wrong_icd_is_dropped_in_text_mode() {
        let ex = Extraction {
            diagnoses: vec![DiagnosisItem {
                text: "2型糖尿病".into(),
                icd: "E11.0".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Text);
        assert_eq!(v.extraction.diagnoses.len(), 0, "SRC 里是 E11.9,不是 E11.0");
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn diagnosis_with_wrong_icd_is_flagged_in_image_mode() {
        let ex = Extraction {
            diagnoses: vec![DiagnosisItem {
                text: "2型糖尿病".into(),
                icd: "E11.0".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, SRC, Mode::Image);
        assert_eq!(v.extraction.diagnoses.len(), 1);
        assert!(v.extraction.diagnoses[0].unverified);
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn image_mode_does_not_fuse_numbers_across_lines() {
        // line1 以 150 结尾,line2 紧接着以 160 开头;归一不许把跨行的两个数字接成 "150160"
        let src = "血红蛋白 HGB 13.5 g/L 115-150\n160 GLU 6.1 mmol/L 3.9-6.1";
        let ex = Extraction {
            labs: vec![LabItem {
                name: "血红蛋白".into(),
                value: "150160".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, src, Mode::Image);
        assert_eq!(v.extraction.labs.len(), 1);
        assert!(
            v.extraction.labs[0].unverified,
            "150 与 160 跨行相邻,不应拼接验真"
        );
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn image_mode_number_normalization_still_matches_comma_decimal() {
        let src = "血糖 GLU 7,1 mmol/L 3.9-6.1";
        let ex = Extraction {
            labs: vec![LabItem {
                name: "血糖".into(),
                value: "7.1".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(ex, src, Mode::Image);
        assert!(!v.extraction.labs[0].unverified, "7,1 归一后应等于 7.1");
        assert_eq!(v.unverified, 0);
    }
}
