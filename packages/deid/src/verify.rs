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
/// 一条**族级病程事实**(spec §3,schema 2)。类型枚举是免疫介导慢病族共用的,
/// 服务端从 prompt 看不出用户是哪个病。
///
/// 扁平结构,不是 12 个变体:所有字段都是**原文逐字字符串**,校验规则完全一样,
/// 消费方按 `type` 取自己关心的那几个。未知 `type` 原样穿过(服务端 prompt 可以
/// 先于 App 加新类型,老 App 忽略它,而不是整份抽取解析失败)。
///
/// `evidence` 必须是原文逐字子串,与 labs 同一套 `verify`(见 [`verify`])。
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct Fact {
    /// `organ_involvement|flare|hospitalization|biopsy|infusion|dose_change|scale|
    /// imaging_finding|infection|pregnancy|vaccination|exam_done`,或任何将来的新值。
    #[serde(rename = "type", default)]
    pub r#type: String,
    #[serde(default)]
    pub organ: String,
    #[serde(default)]
    pub date: String,
    #[serde(default)]
    pub date_start: String,
    #[serde(default)]
    pub date_end: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub result: String,
    #[serde(default)]
    pub drug: String,
    #[serde(default)]
    pub dose: String,
    #[serde(default)]
    pub from: String,
    #[serde(default)]
    pub to: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub modality: String,
    #[serde(default)]
    pub finding: String,
    #[serde(default)]
    pub status: String,
    /// 原文逐字子串。图片档验不过时本条标 `unverified`,界面标「需核对」。
    #[serde(default)]
    pub evidence: String,
    /// 与 `LabItem::unverified` 同一约定:**不在 prompt schema 里**,由 [`verify`] 盖章。
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
    /// schema 2 的族级病程事实。schema 1 的 JSON 里没有这个键 → 空 Vec。
    #[serde(default)]
    pub facts: Vec<Fact>,
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

/// 字段属于数值(化验的 value/ref_low/ref_high)、名字(化验/药品的 name)、
/// 单位、异常标志、受控词表,还是普通文本(其余所有字段)。各类的可接受等价不同,
/// 见 [`field_ok`]。
/// 单位和标志单列出来,是因为它们短到用"全文子串"判定近乎恒真
/// (`g/L` ⊂ `mg/L`,差 1000 倍;`L` ⊂ 任何一个 `1`)。
/// `Enum` 单列出来,是因为它的值**根本不在单据上**:prompt 让模型从我们给的英文
/// 词表里挑一个(`organ`/`status`/`modality`),中文原文里永远查不到它。
#[derive(Clone, Copy)]
enum FieldKind {
    Numeric,
    Name,
    Unit,
    Flag,
    Enum(&'static [&'static str]),
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
// 图片档容错(Task 9b)。容错**只作用于 `Mode::Image`**,文本档一个字都没放宽;
// 反过来,下面那几条**收紧**(单位词边界)两档都管 —— 收紧不是放宽。
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
//
// fix round 1(评审抓出三处「无锚点子串 ⇒ 近乎恒真」)补的硬边界:
//   * 数值:图片档只跟切好词的 `src.numbers` 比;文本档仍逐字子串,但两侧不许
//     再是数字(round 2 补)—— 全文子串会让 `1.5` 被 `11.5` "包含"下来;
//   * 单位要在某个词里整段落下、左右都不是字母 —— `mg/L` 里抠不出 `g/L`;
//   * 名字两边都查不到词典时,再看差的那一个字(钾/钠、左/右);
//   * 异常标志只跟独立成词、长度 ≤2 的词比,且**不走 [`fold_char`]** ——
//     那里 `L→1`、`↑→h`,全文任意一个 `1` 都能验真一个凭空的低值标志。
//
// fix round 2:**异常标志是推导数据,不是证据**。图片档里背书不了的 `flag` 直接
// 清空、这一行照常算验真(值和区间才决定待不待核),由 `parser::labs_from_json`
// 在 `flag` 为空时拿值比区间自己算 H/L。头一版拿标志把整行打成待核,代价是
// 待核里标志类 57 → 327 条,而那批行的**值本身是验真的** —— 用推导数据否定证据,
// 方向反了。文本档不吃这一套:对不上照旧整条丢。
//
// fix round 3(复核抓出的三处残留):
//   * 解析不出数的"数字形状"字段(`0-3`、`1.5%`、`<0.5`)之前落回无边界的
//     `contains`,图片档反倒比文本档松 —— 改走 [`digit_bounded_contains`];
//   * 拆开的单位会伪装成独立的 `L`/`H` 词(`10^9 / L`),见 [`is_unit_fragment`];
//     同一条的下游对策在 `parser::labs_from_json`:**有参考区间时自算的比较压过
//     模型给的字面 H/L**;
//   * 原文那一侧的数字串按**未折叠**的字符切(见 [`number_char`]):`fold_char`
//     把字母折成数字,会把 `2.5L` 读成 `2.51` —— 既假验真,又让真的 `2.5` 假待核。
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

/// 异常标志专用归一:只认「↑=H、↓=L」这一对写法,**绝不走 [`fold_char`]**。
/// 那里 `L→1`、`↑→h`,于是全文任意一个 `1`(`10^9/L`、`11.8`、日期)都能"验真"
/// 一个凭空的低值标志,而下游 `parser::extraction` 对字面 H/L 是优先采信的。
fn fold_flag(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_whitespace())
        .map(|c| match c {
            '↑' => 'H',
            '↓' => 'L',
            '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
            other => other,
        })
        .flat_map(char::to_uppercase)
        .collect()
}

/// 单位被 OCR 拆开时,半截单位会伪装成一个独立的 `L`/`H` 词(`10^9 / L`、`g / L`)。
/// 判据放在**紧挨着的那个词**上:它以 `/ ^ * ×` 收尾(`g/`、`10^9/`),或者它含这些
/// 符号又以数字结尾(`10^9`、`x10`)—— 那就是一截还没写完的单位。
/// 不能只看"前一个词以数字结尾":`血红蛋白 98 L` 里的 `L` 是**真**标志。
fn is_unit_fragment(t: &str) -> bool {
    const GLUE: [char; 5] = ['/', '^', '*', '×', '✕'];
    let last = t.chars().next_back();
    last.is_some_and(|c| GLUE.contains(&c))
        || (t.chars().any(|c| GLUE.contains(&c)) && last.is_some_and(|c| c.is_ascii_digit()))
}

/// 异常标志只跟原文里**独立成词、长度 ≤2** 的词比(H / L / ↑ / ↓ / HH / LL),
/// 不跟全文比 —— 否则 `HGB` 就够"验真"一个 ↑;而且那个词不能是被拆开的单位的
/// 半截(见 [`is_unit_fragment`])。
fn flag_token_match(text: &str, value: &str) -> bool {
    let want = fold_flag(value);
    if want.is_empty() {
        return false;
    }
    let toks: Vec<&str> = text.split_whitespace().collect();
    toks.iter().enumerate().any(|(i, t)| {
        t.chars().count() <= 2
            && fold_flag(t) == want
            && !(i > 0 && is_unit_fragment(toks[i - 1]))
            && !toks
                .get(i + 1)
                .is_some_and(|n| n.starts_with(['/', '^', '*', '×', '✕']))
    })
}

/// 单位必须在原文某个词里**整段**落下,而且紧挨着的左右两边都不是字母。
/// 挡的正是量级前缀:`mg/L` 里抠不出 `g/L`、`mIU/L` 里抠不出 `IU/L`
/// —— 那是 1000 倍之差。符号前缀(`×10^9/L`、`*10^9/L`、`(um/s)`)不算破坏边界,
/// 所以判定看的是**折叠前**的字符(`fold_char` 会把 `×` 折成字母 `x`)。
/// 文本档与图片档都走这条,区别只在图片档比之前先折叠一次。
fn unit_token_match(text: &str, value: &str, tolerant: bool) -> bool {
    let norm = |s: &str| {
        if tolerant {
            fold(s)
        } else {
            s.to_string()
        }
    };
    let want: Vec<char> = norm(value).chars().collect();
    if want.is_empty() {
        return false;
    }
    text.split_whitespace().any(|t| {
        // `fold_char` 一进一出,词内又没有空白,所以 raw 与 f 逐位对齐
        let raw: Vec<char> = t.chars().collect();
        let f: Vec<char> = if tolerant {
            raw.iter().map(|&c| fold_char(c)).collect()
        } else {
            raw.clone()
        };
        if want.len() > f.len() {
            return false;
        }
        (0..=f.len() - want.len()).any(|i| {
            f[i..i + want.len()] == want[..]
                && !(i > 0 && raw[i - 1].is_alphabetic())
                && !(i + want.len() < raw.len() && raw[i + want.len()].is_alphabetic())
        })
    })
}

/// 文本档的数值:仍是逐字子串,但**两侧不许再是数字**。
/// `1.5` 不许从 `11.5` 里抠出来、`0.5` 不许从 `10.5` 里抠出来 —— 图片档那条
/// 「只跟切好词的数字比」的文本档版本。同样是收紧,不是放宽。
fn digit_bounded_contains(text: &str, value: &str) -> bool {
    let (t, v): (Vec<char>, Vec<char>) = (text.chars().collect(), value.chars().collect());
    if v.is_empty() || v.len() > t.len() {
        return false;
    }
    (0..=t.len() - v.len()).any(|i| {
        t[i..i + v.len()] == v[..]
            && !(i > 0 && t[i - 1].is_ascii_digit())
            && !(i + v.len() < t.len() && t[i + v.len()].is_ascii_digit())
    })
}

/// 把一个字段解析成数。折叠后必须**原串里本来就有阿拉伯数字**才算数——
/// 否则 `SOS` 会被折成 `505`,凭空变出一个能对上的数值。
fn parse_num(s: &str) -> Option<f64> {
    // 全角数字也算"本来就有数字"——否则 `５.６` 走不进数值相等那条路,
    // 会掉到下面按文本比的分支上(fix round 3 发现)。
    if !s
        .chars()
        .any(|c| c.is_ascii_digit() || ('\u{FF10}'..='\u{FF19}').contains(&c))
    {
        return None;
    }
    fold(s)
        .trim_start_matches('+')
        .parse::<f64>()
        .ok()
        .filter(|v| v.is_finite())
}

/// 数字串里能出现的字符,**全角归一,但字母一律不算**。
/// 这是与 [`fold_char`] 的关键区别:那张表把 `l/I/O/S/B` 折成数字,用来读原文的
/// 数字串就会把 `2.5L` 读成 `2.51`、`5L` 读成 `51` —— 既凭空造出一个能被假值对上的
/// 数,又让真正的 `2.5` 对不上。字母**结束**一个数,不参与组成它。
fn number_char(c: char) -> Option<char> {
    let c = match c {
        '\u{FF10}'..='\u{FF19}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c), // 全角数字
        '\u{FF0E}' => '.',
        '\u{FF0C}' => ',',
        other => other,
    };
    match c {
        '0'..='9' | '.' => Some(c),
        ',' => Some('.'), // 化验单上 `13,5` 就是 13.5
        _ => None,
    }
}

/// 原文里出现过的数值。**先按空白切词**再在词内找数字串:空白分开的两个数字
/// 不许拼成一个更长的数(旧注释里的跨行拼接误判,同一个坑);词内遇到字母或
/// 别的符号也断开(`2.5L` 给的是 `2.5`,不是 `2.51`)。
fn source_numbers(text: &str) -> Vec<f64> {
    let mut out = Vec::new();
    for tok in text.split_whitespace() {
        let mut run = String::new();
        // 末尾补一个哨兵字符,让最后一段数字也走一次收尾
        for c in tok.chars().chain(std::iter::once('\u{0}')) {
            match number_char(c) {
                Some(n) => run.push(n),
                None => {
                    if let Some(n) = run
                        .trim_matches('.')
                        .parse::<f64>()
                        .ok()
                        .filter(|v: &f64| v.is_finite())
                    {
                        out.push(n);
                    }
                    run.clear();
                }
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

/// 对立修饰字:`terminology` 查不到,但换一个就是另一处/另一种结果。
/// ponytail: 手列四对,不是通用规则;要真覆盖全,得给词典补解剖部位与修饰词。
const OPPOSITE_CHARS: &[(char, char)] = &[('左', '右'), ('上', '下'), ('内', '外'), ('阴', '阳')];

/// 编辑距离 1 的那一处**替换**是不是换了意思:两个字各自能被词典解析成**不同**
/// 术语(钾→potassium / 钠→sodium),或本身就是一对对立字(左/右)。
/// 插入/删除(OCR 断字、多识一个字)不算 —— 那才是误读的典型形状。
fn substitution_changes_meaning(a: &[char], b: &[char]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diffs = a.iter().zip(b).filter(|(x, y)| x != y);
    let Some((&x, &y)) = diffs.next() else {
        return false;
    };
    if diffs.next().is_some() {
        return false;
    }
    if OPPOSITE_CHARS
        .iter()
        .any(|&(p, q)| (p, q) == (x, y) || (p, q) == (y, x))
    {
        return true;
    }
    let key = |c: char| terminology::resolve(&c.to_string(), None).map(|m| m.key);
    matches!((key(x), key(y)), (Some(kx), Some(ky)) if kx != ky)
}

/// 每份文档算一次的原文索引。`keys` 是懒的:只有名字连折叠比对和模糊都没过
/// 的时候才会去建,建一次全文档共用(`terminology::resolve` 未命中时要扫词典,
/// 不值得每个字段重来一遍)。
struct Src<'a> {
    text: &'a str,
    num: String,
    ws: String,
    folded: String,
    /// 折叠但**保留空白**:数值那条带锚点的比对要靠空白撑住词边界,
    /// 拿去空白的 `folded` 比,`5.6` 和 `10^9/L` 会粘成 `5.610^9/1` 而假待核。
    folded_spaced: String,
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
            folded_spaced: text.chars().map(fold_char).collect(),
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
    /// **两道护栏**:
    /// 1. 那段前缀本身能被词典解析成另一个术语时不放行(红细胞/白细胞);
    /// 2. 两边都查不到词典时(词典外的名字恰恰是风险最高的那批),退一步看
    ///    差的那一个字 —— 钾/钠、左/右 各自就是不同的东西,不是误读。
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
                let src_key = terminology::resolve(&s, None).map(|m| m.key);
                match (src_key.as_deref(), value_key) {
                    // 两边都是词典里的真术语,而且不是同一个 → 是邻项,不是误读
                    (Some(m), Some(k)) if m != k => continue,
                    _ if substitution_changes_meaning(&v, &cand[..w]) => continue,
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
    // 单位两档都走词边界:`g/L` 不许从 `mg/L` 里抠出来,文本档同样中招过。
    if let FieldKind::Unit = kind {
        return unit_token_match(src.text, value, matches!(mode, Mode::Image));
    }
    // 受控词表字段:值来自 **prompt 给的那张表**,不是单据上的字 —— 一份写着
    // 「狼疮性肾炎(IV型)」的中文出院小结里没有 `kidney` 这七个字母,拿它去查
    // 原文子串等于把这一族 fact 全判假、静默丢掉(终审 I2)。表里有就算数。
    // 表外的值不放行、退回逐字那条老路:`biopsy.organ` 在 prompt 里本来就是原文
    // 自由文本(`"organ":""`),它得继续按原文逐字验。
    // 这道门只管**取值域**;fact 与原文的绑定仍然只由 `evidence` 那条逐字锚点
    // 负责,一寸没动。
    if let FieldKind::Enum(allowed) = kind {
        if allowed.iter().any(|v| v.eq_ignore_ascii_case(value)) {
            return true;
        }
    }
    if let Mode::Text = mode {
        return match kind {
            // 数值同样要锚点:逐字子串会让 `1.5` 被 `11.5` 收下(fix round 2)
            FieldKind::Numeric => digit_bounded_contains(src.text, value),
            _ => src.text.contains(value),
        };
    }
    match kind {
        FieldKind::Unit => unreachable!("单位在 mode 分流之前已经返回"),
        FieldKind::Flag => flag_token_match(src.text, value),
        FieldKind::Numeric => match parse_num(value) {
            // 相等,不是接近:`==` 是这条规则的全部内容,别换成 eps 比较。
            // **只**跟切好词的 `src.numbers` 比:全文子串没有锚点,`1.5` 会被
            // `11.5` "包含"下来而验真。
            Some(n) => src.numbers.contains(&n),
            // 解析不出数(`阴性`、`<2.00`、`0-3`、`2.61*`)就按文本比,但**同样要锚点**
            // —— 光 `contains` 会让 `0-3` 被 `10-30`、`1.5%` 被 `11.5%` 验真,
            // 那正是图片档比文本档还松的一处(fix round 3)。
            None => {
                digit_bounded_contains(&src.num, &comma_between_digits_to_dot(value))
                    || digit_bounded_contains(&src.folded_spaced, &fold(value))
            }
        },
        FieldKind::Text | FieldKind::Enum(_) => {
            src.ws.contains(&strip_ws(value)) || src.folded.contains(&fold(value))
        }
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

/// spec §3 的族级 `Fact.type` 允许值(与 `Fact` 结构体文档同一份清单)。
/// `parse_extraction` 仍容忍清单外的新 type(server 端 prompt 可以先于 App 加新
/// 类型,见 Task 5 `an_unknown_fact_type_survives_parsing_...`),但 `verify()`
/// 不会把它当验真事实放行——未知 type 与其它字段一样,文本档丢、图片档标
/// `unverified`(fix round 1 finding 6)。
const KNOWN_FACT_TYPES: &[&str] = &[
    "organ_involvement",
    "flare",
    "hospitalization",
    "biopsy",
    "infusion",
    "dose_change",
    "scale",
    "imaging_finding",
    "infection",
    "pregnancy",
    "vaccination",
    "exam_done",
];

/// prompt(`prompts/extract_v2_system.txt`)里写成 `a|b|c` 的那三个受控词表字段的
/// 允许值,**与 prompt 逐字同一份清单**。改了 prompt 就得改这里:多出来的那个值
/// 会被当成原文逐字去查,查不到就整条 fact 静默丢掉。
const ORGAN_VALUES: &[&str] = &[
    "kidney", "blood", "skin", "joint", "cns", "serosa", "lung", "gi", "eye", "other",
];
const PREGNANCY_STATUS_VALUES: &[&str] = &["planning", "pregnant", "postpartum"];
const IMAGING_MODALITY_VALUES: &[&str] = &["MRI", "CT", "OCT", "DXA", "US", "endoscopy"];

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
            && field_ok(&l.unit, &src, mode, FieldKind::Unit)
            && field_ok(&l.ref_low, &src, mode, FieldKind::Numeric)
            && field_ok(&l.ref_high, &src, mode, FieldKind::Numeric);
        let flag_ok = field_ok(&l.flag, &src, mode, FieldKind::Flag);
        match mode {
            // 图片档:异常标志是**推导数据**,值和区间才是证据。原文背书不了的标志
            // 直接清空,让 `parser::labs_from_json` 拿值比区间自己算 H/L —— 不因为
            // 一个推导不出处的标志把整行打成待核。值没过的行照样待核,与标志无关。
            Mode::Image => {
                if !flag_ok {
                    l.flag.clear();
                }
                keep(ok, &mut l.unverified)
            }
            // 文本档一个字都没放宽:标志对不上,整条照丢。
            Mode::Text => keep(ok && flag_ok, &mut l.unverified),
        }
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

    // 族级病程事实(spec §3):与 labs/meds/diagnoses 同一套逐字校验,**每个字符串
    // 字段都查**,不是只查 `evidence`(fix round 1,评审 c60205d..79497a0)。
    // 按字段语义分型,不是一律 `FieldKind::Text`:
    //   * `value`/`dose`/`from`/`to` 走 `Numeric` —— 裸 `contains` 没有数字边界,
    //     `15` 会背书 `5`、`580mg` 会背书 `80mg`(finding 1);图片档下 `Text` 的
    //     字母→数字折叠(`s→5,l→1,i→1`,见 `fold_char`)还会让纯字母的 "SLEDAI"
    //     凭空造出分数 "51"(finding 2)——`Numeric` 两档都不折叠字母,天然挡住。
    //   * `drug`/`name` 走 `Name`,与 `MedItem.name` 同一条模糊规则,否则同一个
    //     药名在 meds 验真、在 facts 却被打待核(finding 5)。
    //   * `organ`/`status`/`modality` 走 `Enum`:prompt 把它们定义成英文受控词表,
    //     中文原文里根本没有 `kidney`/`pregnant`/`MRI` 这些字,按原文逐字查一律
    //     判假 —— 文本档整条丢、图片档恒「需核对」,里程碑起算日与妊娠时间轴因此
    //     在真实数据上是死路(终审 I2)。
    //   * 其余(`date*`/`text`/`reason`/`result`/`finding`)仍是 `Text`:纯文本
    //     字段,没有数字边界或术语模糊的需求。
    // `evidence` 不进这套字段分派:它是锚点,`field_ok` 对空串恒过、`FieldKind::Text`
    // 图片档还会折叠容错,两条都会把这道最后防线放水(finding 3/4)——空串必须是
    // 硬失败,且两档都要求原文**逐字**(`src.text.contains`,不去空白、不折叠)。
    // `type` 也单独查:未知 type 不当验真事实放行(finding 6),但解析阶段仍容忍
    // 未知 type(见 Task 5 `an_unknown_fact_type_survives_parsing_...`)——两者不冲突,
    // 前者是 `verify()` 的事,后者是 `parse_extraction()` 的事。
    e.facts.retain_mut(|f| {
        let evidence_ok = !f.evidence.is_empty() && src.text.contains(&f.evidence);
        let type_ok = KNOWN_FACT_TYPES.contains(&f.r#type.as_str());
        // ponytail: evidence 核验是全文子串,不认段落边界——抄自不相干段落的句子
        // 照样能给任意一条 fact 背书(评审实测:拿「否认糖尿病」给 infection 背书
        // 通过)。真要收紧到「同一段」,得先给 Src 加分段索引;今天没有消费方逼近
        // 这个洞,先留着,升级路径见 `Src`。
        let ok = evidence_ok
            && type_ok
            && [
                (&f.organ, FieldKind::Enum(ORGAN_VALUES)),
                (&f.date, FieldKind::Text),
                (&f.date_start, FieldKind::Text),
                (&f.date_end, FieldKind::Text),
                (&f.text, FieldKind::Text),
                (&f.reason, FieldKind::Text),
                (&f.result, FieldKind::Text),
                (&f.drug, FieldKind::Name),
                (&f.dose, FieldKind::Numeric),
                (&f.from, FieldKind::Numeric),
                (&f.to, FieldKind::Numeric),
                (&f.name, FieldKind::Name),
                (&f.value, FieldKind::Numeric),
                (&f.modality, FieldKind::Enum(IMAGING_MODALITY_VALUES)),
                (&f.finding, FieldKind::Text),
                (&f.status, FieldKind::Enum(PREGNANCY_STATUS_VALUES)),
            ]
            .into_iter()
            .all(|(s, kind)| field_ok(s, &src, mode, kind));
        keep(ok, &mut f.unverified)
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

    #[test]
    fn schema_one_json_still_parses_and_yields_no_facts() {
        // 老 App 发 schema 1,老保险箱里躺着 schema 1 的结果 —— 加了 facts 之后
        // 它们必须照样解析,而不是整条抽取变成解析失败。
        let old = r#"{"doc_type":"lab","doc_date":"2026-01-01","labs":[],"meds":[],
                      "diagnoses":[],"impression":"","notes":""}"#;
        let e = parse_extraction(old).expect("schema 1 必须继续解析");
        assert!(e.facts.is_empty());
    }

    #[test]
    fn facts_parse_with_only_the_fields_that_type_uses() {
        let j = r#"{"labs":[],"facts":[
            {"type":"organ_involvement","organ":"kidney","date":"2024-03-02",
             "text":"狼疮性肾炎 IV 型","evidence":"狼疮性肾炎 IV 型"},
            {"type":"dose_change","drug":"泼尼松","from":"30mg","to":"20mg",
             "date":"2024-06-01","evidence":"泼尼松减至 20mg"},
            {"type":"hospitalization","date_start":"2024-03-01","date_end":"2024-03-12",
             "reason":"狼疮活动","evidence":"因狼疮活动收入院"}]}"#;
        let e = parse_extraction(j).expect("facts 必须解析");
        assert_eq!(e.facts.len(), 3);
        assert_eq!(e.facts[0].r#type, "organ_involvement");
        assert_eq!(e.facts[0].organ, "kidney");
        assert_eq!(e.facts[0].text, "狼疮性肾炎 IV 型");
        assert_eq!(e.facts[1].drug, "泼尼松");
        assert_eq!(e.facts[1].from, "30mg");
        assert_eq!(e.facts[1].to, "20mg");
        assert_eq!(e.facts[2].date_start, "2024-03-01");
        assert_eq!(e.facts[2].date_end, "2024-03-12");
        // 这一族没用到的字段一律空串,不是 None、不是缺席。
        assert_eq!(e.facts[0].drug, "");
        assert!(!e.facts[0].unverified);
    }

    #[test]
    fn an_unknown_fact_type_survives_parsing_instead_of_failing_the_document() {
        // 服务端的 prompt 可以先于 App 加新 type。老 App 必须能把整份抽取收下来
        // (labs 照常入库),只是忽略认不出的那一条 —— 不能整份丢掉。
        let j = r#"{"labs":[],"facts":[{"type":"something_new_2027","text":"x","evidence":"x"}]}"#;
        let e = parse_extraction(j).expect("未知 type 不该让解析失败");
        assert_eq!(e.facts[0].r#type, "something_new_2027");
    }

    // --- Task 6: facts 走与 labs/meds/diagnoses 同一套逐字校验 ---

    const FACT_SRC: &str = "出院诊断:系统性红斑狼疮 狼疮性肾炎 IV 型\n泼尼松减至 20mg qd";

    fn fact(t: &str, text: &str, evidence: &str) -> Fact {
        Fact {
            r#type: t.into(),
            text: text.into(),
            evidence: evidence.into(),
            ..Default::default()
        }
    }

    #[test]
    fn text_mode_drops_a_fact_whose_evidence_is_not_in_the_source() {
        let e = Extraction {
            facts: vec![
                fact("organ_involvement", "狼疮性肾炎 IV 型", "狼疮性肾炎 IV 型"),
                fact("flare", "病情活动加重", "患者病情明显加重需大剂量激素"), // 原文没有
            ],
            ..Default::default()
        };
        let v = verify(e, FACT_SRC, Mode::Text);
        assert_eq!(v.extraction.facts.len(), 1);
        assert_eq!(v.extraction.facts[0].r#type, "organ_involvement");
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn image_mode_keeps_the_fact_but_marks_it_unverified() {
        let e = Extraction {
            facts: vec![fact(
                "flare",
                "病情活动加重",
                "患者病情明显加重需大剂量激素",
            )],
            ..Default::default()
        };
        let v = verify(e, FACT_SRC, Mode::Image);
        assert_eq!(v.extraction.facts.len(), 1);
        assert!(v.extraction.facts[0].unverified);
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn every_string_field_of_a_fact_is_checked_not_just_evidence() {
        // `drug`/`from`/`to` 直接决定界面上「泼尼松 30mg → 20mg」这句话。
        // 只查 evidence、放任其它字段,等于让模型在这几个字段上自由发挥。
        let e = Extraction {
            facts: vec![Fact {
                r#type: "dose_change".into(),
                drug: "泼尼松".into(),
                from: "30mg".into(), // 原文里没有 30mg
                to: "20mg".into(),
                evidence: "泼尼松减至 20mg".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(e, FACT_SRC, Mode::Text);
        assert!(
            v.extraction.facts.is_empty(),
            "from 对不上原文,整条应当丢弃"
        );
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn an_empty_field_is_not_a_verification_failure() {
        // 扁平结构里绝大多数字段对某一族是空的,空串必须恒过 —— 否则每条 fact 都被毙。
        let e = Extraction {
            facts: vec![fact(
                "organ_involvement",
                "狼疮性肾炎 IV 型",
                "狼疮性肾炎 IV 型",
            )],
            ..Default::default()
        };
        let v = verify(e, FACT_SRC, Mode::Text);
        assert_eq!(v.extraction.facts.len(), 1);
        assert_eq!(v.rejected, 0);
    }

    // --- Task 6 fix round 1: 数值边界 / 字母折叠 / evidence 强制非空且逐字 /
    // drug·name 走 Name / type 白名单(评审 c60205d..79497a0 抓出的七个洞) ---

    const FACT_SRC2: &str = "泼尼松减至 20mg qd\nSLEDAI 评分 15 分\n环磷酰胺 580mg 静脉输注";

    // finding 1:value/dose/from/to 裸 contains 没有数字边界,15 能背书 5、
    // 20mg 能背书 0mg、580mg 能背书 80mg。三个陷阱各一条测试。

    #[test]
    fn text_mode_scale_value_needs_a_digit_boundary_not_bare_contains() {
        let f = Fact {
            r#type: "scale".into(),
            name: "SLEDAI".into(),
            value: "5".into(), // 原文是 15,裸 contains 会被背书
            evidence: "SLEDAI 评分 15 分".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC2,
            Mode::Text,
        );
        assert!(
            v.extraction.facts.is_empty(),
            "value=5 不该被原文的 15 背书"
        );
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn text_mode_dose_change_to_needs_a_digit_boundary() {
        let f = Fact {
            r#type: "dose_change".into(),
            drug: "泼尼松".into(),
            to: "0mg".into(), // 原文是 20mg
            evidence: "泼尼松减至 20mg qd".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC2,
            Mode::Text,
        );
        assert!(
            v.extraction.facts.is_empty(),
            "to=0mg 不该被原文的 20mg 背书"
        );
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn text_mode_infusion_dose_needs_a_digit_boundary() {
        let f = Fact {
            r#type: "infusion".into(),
            drug: "环磷酰胺".into(),
            dose: "80mg".into(), // 原文是 580mg
            evidence: "环磷酰胺 580mg 静脉输注".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC2,
            Mode::Text,
        );
        assert!(
            v.extraction.facts.is_empty(),
            "dose=80mg 不该被原文的 580mg 背书"
        );
        assert_eq!(v.rejected, 1);
    }

    // finding 2:图片档 `FieldKind::Text` 的字母折叠(s→5、l→1、i→1)会让纯字母的
    // "SLEDAI" 凭空造出数字 "51"。数值字段必须不走这条折叠。

    #[test]
    fn image_mode_numeric_field_does_not_let_letters_fold_into_digits() {
        let f = Fact {
            r#type: "scale".into(),
            name: "SLEDAI".into(),
            value: "51".into(), // 原文只有单词 SLEDAI,没有任何数字
            evidence: "SLEDAI".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            "SLEDAI",
            Mode::Image,
        );
        assert_eq!(v.extraction.facts.len(), 1);
        assert!(
            v.extraction.facts[0].unverified,
            "51 不该靠字母→数字折叠验真"
        );
        assert_eq!(v.unverified, 1);
    }

    // finding 3:空 evidence 是免检通行证。

    #[test]
    fn text_mode_drops_a_fact_with_empty_evidence() {
        let f = Fact {
            r#type: "flare".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC,
            Mode::Text,
        );
        assert!(v.extraction.facts.is_empty(), "空 evidence 不能免检");
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn image_mode_flags_a_fact_with_empty_evidence() {
        let f = Fact {
            r#type: "flare".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC,
            Mode::Image,
        );
        assert_eq!(v.extraction.facts.len(), 1);
        assert!(
            v.extraction.facts[0].unverified,
            "空 evidence 图片档也要标待核"
        );
        assert_eq!(v.unverified, 1);
    }

    // finding 4:图片档 evidence 走的是 `FieldKind::Text` 的折叠容错,
    // 大写 O 会被折成数字 0,"2Omg" 因此能验真 "20mg"。evidence 两档都必须逐字。

    #[test]
    fn image_mode_evidence_is_verbatim_not_fold_tolerant() {
        let f = Fact {
            r#type: "dose_change".into(),
            to: "20mg".into(),
            evidence: "泼尼松减至 2Omg qd".into(), // 大写字母 O,不是数字 0
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC,
            Mode::Image,
        );
        assert_eq!(v.extraction.facts.len(), 1);
        assert!(
            v.extraction.facts[0].unverified,
            "evidence 里的字母 O 不是原文的数字 0,不该折叠验真"
        );
        assert_eq!(v.unverified, 1);
    }

    // finding 5:drug/name 应与 `MedItem.name` 同一条模糊规则(edit distance ≤1 的
    // OCR 误读),否则同一个药名在 meds 验真、在 facts 却被打待核。与
    // `med_name_uses_the_same_name_rule`(tests/verify_tolerant.rs)同一对字符串。

    #[test]
    fn image_mode_fact_drug_gets_the_same_fuzzy_name_rule_as_med_name() {
        let f = Fact {
            r#type: "infusion".into(),
            drug: "阿司匹林肠溶片".into(), // 原文是「休」,editdistance 1
            evidence: "阿司匹休肠溶片 100mg 每日一次".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            "阿司匹休肠溶片 100mg 每日一次",
            Mode::Image,
        );
        assert!(
            !v.extraction.facts[0].unverified,
            "drug 应与 meds.name 同一条模糊规则,不该被打待核"
        );
    }

    // finding 6:`type` 不在白名单里的 fact,不该被当验真事实放行——但解析阶段
    // 仍要容忍未知 type(Task 5 的 `an_unknown_fact_type_survives_parsing_...` 不变)。

    #[test]
    fn text_mode_drops_a_fact_with_an_unknown_type() {
        let f = Fact {
            r#type: "something_new_2027".into(),
            text: "狼疮性肾炎 IV 型".into(),
            evidence: "狼疮性肾炎 IV 型".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC,
            Mode::Text,
        );
        assert!(
            v.extraction.facts.is_empty(),
            "未知 type 不该被当验真事实放行"
        );
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn image_mode_flags_a_fact_with_an_unknown_type() {
        let f = Fact {
            r#type: "something_new_2027".into(),
            text: "狼疮性肾炎 IV 型".into(),
            evidence: "狼疮性肾炎 IV 型".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC,
            Mode::Image,
        );
        assert_eq!(v.extraction.facts.len(), 1);
        assert!(v.extraction.facts[0].unverified);
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn all_twelve_spec_fact_types_are_in_the_allowlist() {
        for t in [
            "organ_involvement",
            "flare",
            "hospitalization",
            "biopsy",
            "infusion",
            "dose_change",
            "scale",
            "imaging_finding",
            "infection",
            "pregnancy",
            "vaccination",
            "exam_done",
        ] {
            let f = Fact {
                r#type: t.into(),
                evidence: "x".into(),
                ..Default::default()
            };
            let v = verify(
                Extraction {
                    facts: vec![f],
                    ..Default::default()
                },
                "x",
                Mode::Text,
            );
            assert_eq!(v.extraction.facts.len(), 1, "type={t} 应在白名单内");
        }
    }

    // --- 终审 fix round 1(I2):prompt 写成英文受控词表的字段按词表校验 ---

    /// 词表值 + 逐字 evidence:文本档过,且不带「需核对」。
    /// 修之前这条在文本档整条被丢 —— 中文小结里没有 `kidney` 这七个字母,而
    /// `milestone_t0` 的器官分支只认验真的 fact,里程碑起算日因此永远退到
    /// 「最早一次处方」那条兜底上。
    #[test]
    fn text_mode_verifies_an_organ_taken_from_the_prompt_vocabulary() {
        let f = Fact {
            r#type: "organ_involvement".into(),
            organ: "kidney".into(),
            text: "狼疮性肾炎 IV 型".into(),
            evidence: "狼疮性肾炎 IV 型".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC,
            Mode::Text,
        );
        assert_eq!(v.extraction.facts.len(), 1, "词表里的值不该判假");
        assert!(!v.extraction.facts[0].unverified);
        assert_eq!(v.rejected, 0);
    }

    /// 同一条在图片档也得是**验真**,不是「留着标需核对」。
    #[test]
    fn image_mode_verifies_an_organ_taken_from_the_prompt_vocabulary() {
        let f = Fact {
            r#type: "organ_involvement".into(),
            organ: "kidney".into(),
            text: "狼疮性肾炎 IV 型".into(),
            evidence: "狼疮性肾炎 IV 型".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC,
            Mode::Image,
        );
        assert_eq!(v.extraction.facts.len(), 1);
        assert!(!v.extraction.facts[0].unverified, "词表命中不该标需核对");
        assert_eq!(v.unverified, 0);
    }

    /// 词表外的值**不**放行:退回逐字那条老路,原文里也没有它。
    #[test]
    fn text_mode_drops_a_fact_whose_organ_is_outside_the_prompt_vocabulary() {
        let f = Fact {
            r#type: "organ_involvement".into(),
            organ: "pancreas".into(), // 词表里没有,原文里也没有
            evidence: "狼疮性肾炎 IV 型".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC,
            Mode::Text,
        );
        assert!(v.extraction.facts.is_empty(), "词表外的值不许当验真放行");
        assert_eq!(v.rejected, 1);
    }

    /// 图片档同理:词表外的 `status` 留着,但必须举着「需核对」。
    #[test]
    fn image_mode_flags_a_status_outside_the_prompt_vocabulary() {
        let f = Fact {
            r#type: "pregnancy".into(),
            status: "married".into(), // planning|pregnant|postpartum 之外
            evidence: "狼疮性肾炎 IV 型".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC,
            Mode::Image,
        );
        assert_eq!(v.extraction.facts.len(), 1);
        assert!(v.extraction.facts[0].unverified);
        assert_eq!(v.unverified, 1);
    }

    /// 另两个词表字段各一条,证明三份清单都接上了。
    #[test]
    fn the_other_two_vocabulary_fields_verify_too() {
        for f in [
            Fact {
                r#type: "pregnancy".into(),
                status: "pregnant".into(),
                evidence: "狼疮性肾炎 IV 型".into(),
                ..Default::default()
            },
            Fact {
                r#type: "imaging_finding".into(),
                modality: "MRI".into(),
                evidence: "狼疮性肾炎 IV 型".into(),
                ..Default::default()
            },
        ] {
            let t = f.r#type.clone();
            let v = verify(
                Extraction {
                    facts: vec![f],
                    ..Default::default()
                },
                FACT_SRC,
                Mode::Text,
            );
            assert_eq!(v.extraction.facts.len(), 1, "{t} 的词表值应当验真");
        }
    }

    /// 两份清单必须**逐字**一致:prompt 里 `"organ":"kidney|blood|…"` 那一段就是
    /// `ORGAN_VALUES`。谁改了一边没改另一边,多出来的那个值就会被当原文逐字去查,
    /// 查不到 → 整条 fact 静默丢掉 —— 正是终审 I2 那个洞的形状。
    #[test]
    fn the_vocabularies_are_the_prompt_lists_verbatim() {
        const PROMPT: &str = include_str!("../prompts/extract_v2_system.txt");
        for (field, values) in [
            ("organ", ORGAN_VALUES),
            ("status", PREGNANCY_STATUS_VALUES),
            ("modality", IMAGING_MODALITY_VALUES),
        ] {
            let want = format!("\"{field}\":\"{}\"", values.join("|"));
            assert!(PROMPT.contains(&want), "prompt 里找不到 {want}");
        }
    }

    /// `biopsy.organ` 在 prompt 里是**原文自由文本**(`"organ":""`),不是词表 ——
    /// 词表这道门只是多一条路,老的逐字路不能被它顶掉。
    #[test]
    fn a_biopsy_organ_written_verbatim_in_chinese_still_verifies() {
        let f = Fact {
            r#type: "biopsy".into(),
            organ: "狼疮性肾炎".into(),
            evidence: "狼疮性肾炎 IV 型".into(),
            ..Default::default()
        };
        let v = verify(
            Extraction {
                facts: vec![f],
                ..Default::default()
            },
            FACT_SRC,
            Mode::Text,
        );
        assert_eq!(v.extraction.facts.len(), 1);
        assert_eq!(v.rejected, 0);
    }
}
