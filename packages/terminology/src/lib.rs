//! Clinical terminology normalization layer.
//!
//! A static, versioned dictionary (`dictionary.json`, compiled in via
//! `include_str!`) plus a single lookup function [`normalize`]. It maps a raw
//! Chinese/English/abbreviation/OCR-split term to an internal canonical key +
//! canonical Chinese name + international codes (LOINC / RxNorm / ATC + OMOP
//! standard concept_id) + canonical unit + explicit unit conversions.
//!
//! This layer has no runtime "value": it does not perform conversions itself.
//! Instead each accepted source unit carries an affine conversion written into
//! the data, so any consumer can compute with zero ambiguity:
//!
//! ```text
//! canonical_value = slope * source_value + intercept
//! ```
//!
//! Design: `docs/superpowers/specs/2026-07-10-terminology-normalization-layer-design.md`.

use serde::Deserialize;
use std::collections::HashMap;
use std::sync::OnceLock;

/// The compiled-in dictionary. A parse failure here is a build-time bug in the
/// shipped resource, not a runtime condition — see [`index`].
const DICTIONARY_JSON: &str = include_str!("../dictionary.json");

/// What kind of clinical concept an entry describes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Category {
    Lab,
    Vital,
    Drug,
}

/// International codes for a concept. Each is a separate slot — multiple coding
/// systems are never collapsed into one field (design §6 red line 4). Absent
/// codes are `None`.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Codes {
    #[serde(default)]
    pub loinc: Option<String>,
    #[serde(default)]
    pub rxnorm: Option<String>,
    #[serde(default)]
    pub atc: Option<String>,
    #[serde(default)]
    pub omop_concept_id: Option<i64>,
}

/// One accepted source unit and its affine conversion to the entry's
/// `canonical_unit`: `canonical_value = slope * source_value + intercept`.
/// The canonical unit itself is the row `slope = 1, intercept = 0`.
#[derive(Debug, Clone, Deserialize)]
pub struct UnitConversion {
    /// UCUM unit notation, e.g. `umol/L`, `mg/dL`, `10*9/L`, `mmol/mol`.
    pub unit: String,
    pub slope: f64,
    pub intercept: f64,
}

/// A single dictionary entry (lab / vital / drug). Lab and vital entries carry
/// `system` / `canonical_unit` / `units`; drug entries carry `ingredient`.
#[derive(Debug, Clone, Deserialize)]
pub struct Entry {
    /// Internal canonical key, e.g. `creatinine`, `metformin`.
    pub key: String,
    /// Canonical Chinese display name.
    pub canonical_name: String,
    pub category: Category,
    /// LOINC specimen, e.g. `serum/plasma` — keeps serum ≠ urine from
    /// collapsing (design §6 red line 2). `None` for drugs.
    #[serde(default)]
    pub system: Option<String>,
    /// 检验大类(化验报告单印刷惯例,不是临床判断) —— 血常规/肝功能/肾功能等,
    /// 见 `panel_methodology.md`。与 `system`(标本类型)是两个独立维度:
    /// `system` 太粗(181 条同为 `serum/plasma`,肝肾血脂血糖全混在一起)。
    /// `None` 表示这条没能干净地归进策展的 ~14 类里,老实留空,消费方(手机端
    /// 趋势页)落进「其他」兜底,不强凑。只有 `category == Lab` 的条目会有值;
    /// vital/drug 恒为 `None`——这是化验报告单的项目组表头,体征/药物没有这个
    /// 概念。**只给一个**(不像 `problem_map.json` 的疾病泳道允许多重归属):
    /// 一项化验在真实报告单上物理上只印在一个项目组表头下。
    #[serde(default)]
    pub panel: Option<String>,
    pub codes: Codes,
    /// Canonical unit (UCUM). `None` for drugs.
    #[serde(default)]
    pub canonical_unit: Option<String>,
    /// Explicit conversions; empty for drugs.
    #[serde(default)]
    pub units: Vec<UnitConversion>,
    /// Active ingredient (English); `Some` only for drugs.
    #[serde(default)]
    pub ingredient: Option<String>,
    /// Exact aliases — a normalized hit yields confidence 1.0.
    pub aliases: Vec<String>,
    /// Known OCR misreads — a normalized hit yields confidence 0.5 (suspect,
    /// routed to human review rather than trusted).
    #[serde(default)]
    pub ocr_confusions: Vec<String>,
    /// Human-readable caveat about this entry's coding/conversion choices, e.g.
    /// a deliberate non-standard concept or a source-unit assumption.
    #[serde(default)]
    pub note: Option<String>,
}

/// Top-level dictionary document.
#[derive(Debug, Clone, Deserialize)]
pub struct Dictionary {
    pub version: String,
    pub entries: Vec<Entry>,
}

/// A successful normalization. Mapping is always *additive*: the caller keeps
/// the original raw term + span; this only annotates it (design §6 red line 1).
#[derive(Debug, Clone)]
pub struct Match {
    pub key: String,
    pub canonical_name: String,
    pub category: Category,
    pub codes: Codes,
    /// Active ingredient (drugs only).
    pub ingredient: Option<String>,
    /// The dictionary alias that matched (traceable back to the data).
    pub matched_alias: String,
    /// 1.0 = 字典别名精确命中;0.8 = **剥壳推断**(去盐基/剂型/规格/载液后才命中,是推断
    /// 不是原文);0.5 = OCR 混淆表命中(可疑,送人工复核)。上层据此决定信不信。
    pub confidence: f32,
}

/// A resolved alias: which entry it belongs to and the original alias text.
struct AliasHit {
    entry_idx: usize,
    alias: String,
}

/// Lazily-built lookup index over the dictionary.
struct Index {
    entries: Vec<Entry>,
    /// normalized alias -> hit (confidence 1.0)。**化验/体征优先**:见 [`build_index`]。
    aliases: HashMap<String, AliasHit>,
    /// normalized ocr_confusion -> hit (confidence 0.5).
    confusions: HashMap<String, AliasHit>,
    /// 只含 drug 条目的别名表 —— 处方语境用 [`normalize_drug`] 查这张,
    /// 免得「叶酸」「氢化可的松」被同名的化验项抢走。
    drug_aliases: HashMap<String, AliasHit>,
    /// drug 的 OCR 混淆表(同上,按类别分)。
    drug_confusions: HashMap<String, AliasHit>,
}

/// Normalization applied to BOTH index keys and query terms so lookups are
/// insensitive to case, full-width forms, and internal whitespace (OCR often
/// splits CJK, e.g. `肌 酐` -> `肌酐`). This is the single shared helper the
/// design mandates.
///
/// **Public on purpose, and mandatory.** Any comparison of a Chinese medical
/// term against a curated table — anywhere in the workspace, not just in this
/// crate — must run both sides through this function first. Comparing raw
/// strings is a bug even when it happens to work on the samples at hand:
/// `parser::handoff::match_disease` used to do `contains` on untrimmed text and
/// silently failed on `2 型糖尿病` (typeset with a space) vs the table's
/// `2型糖尿病`, which emptied the diabetes lane in the doctor's viewer while
/// every unit test stayed green — because the tests fed the table's own
/// spelling, not what real documents print.
pub fn normalize_term(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        let ch = to_halfwidth(ch);
        if ch.is_whitespace() {
            continue;
        }
        for lc in ch.to_lowercase() {
            out.push(lc);
        }
    }
    out
}

/// Map a full-width character to its ASCII half-width equivalent. The
/// ideographic space (U+3000) folds to a normal space (then stripped by
/// `normalize_term`); full-width `!`..`~` (U+FF01..U+FF5E) map to ASCII
/// 0x21..0x7E. All other characters pass through unchanged.
fn to_halfwidth(c: char) -> char {
    match c {
        '\u{3000}' => ' ',
        '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
        _ => c,
    }
}

/// Parse the compiled-in dictionary and build the alias/confusion indexes.
///
/// Invariant: `dictionary.json` is a shipped, version-controlled resource that
/// is validated by this crate's tests (including `parse_dictionary` and
/// `no_duplicate_alias_within_category`). A parse failure or duplicate alias is
/// therefore a build-time bug, so `expect` documents that invariant rather than
/// propagating an error that no runtime caller could act on.
///
/// 同名跨类别是**真实存在**的:「叶酸」既是化验(血清叶酸)也是药(叶酸片);「氢化可的松」
/// 既是化验(皮质醇)也是药。别名表按类别
/// 分开建:无类别信息的 [`normalize`] 让**化验/体征优先**(报告单里这些词绝大多数是化验项),
/// 处方语境改用 [`normalize_drug`] 查 drug 专表。同一类别内别名仍必须唯一
/// (`no_duplicate_alias_within_category` 守着)。
fn build_index() -> Index {
    let dict: Dictionary = serde_json::from_str(DICTIONARY_JSON)
        .expect("dictionary.json is a valid, shipped resource");

    let mut aliases: HashMap<String, AliasHit> = HashMap::new();
    let mut confusions: HashMap<String, AliasHit> = HashMap::new();
    let mut drug_aliases: HashMap<String, AliasHit> = HashMap::new();
    let mut drug_confusions: HashMap<String, AliasHit> = HashMap::new();

    for (entry_idx, entry) in dict.entries.iter().enumerate() {
        let is_drug = entry.category == Category::Drug;
        for alias in &entry.aliases {
            let norm = normalize_term(alias);
            let hit = AliasHit {
                entry_idx,
                alias: alias.clone(),
            };
            if is_drug {
                // 化验优先:通用表里已有(必是化验/体征)就不覆盖。
                drug_aliases.insert(norm.clone(), hit);
                aliases.entry(norm).or_insert_with(|| AliasHit {
                    entry_idx,
                    alias: alias.clone(),
                });
            } else {
                aliases.insert(norm, hit);
            }
        }
        for confusion in &entry.ocr_confusions {
            let norm = normalize_term(confusion);
            let hit = AliasHit {
                entry_idx,
                alias: confusion.clone(),
            };
            if is_drug {
                // 与 aliases 同样的分表规则:混淆表也不能让药悄悄盖掉化验项。
                drug_confusions.insert(norm.clone(), hit);
                confusions.entry(norm).or_insert_with(|| AliasHit {
                    entry_idx,
                    alias: confusion.clone(),
                });
            } else {
                confusions.insert(norm, hit);
            }
        }
    }

    Index {
        entries: dict.entries,
        aliases,
        confusions,
        drug_aliases,
        drug_confusions,
    }
}

fn index() -> &'static Index {
    static INDEX: OnceLock<Index> = OnceLock::new();
    INDEX.get_or_init(build_index)
}

impl Index {
    fn to_match(&self, hit: &AliasHit, confidence: f32) -> Match {
        let e = &self.entries[hit.entry_idx];
        Match {
            key: e.key.clone(),
            canonical_name: e.canonical_name.clone(),
            category: e.category,
            codes: e.codes.clone(),
            ingredient: e.ingredient.clone(),
            matched_alias: hit.alias.clone(),
            confidence,
        }
    }
}

/// 剥壳推断出来的命中置信度:低于精确命中(1.0),高于 OCR 混淆(0.5)。「盐酸二甲双胍片」
/// 剥成「二甲双胍」是**推断**——原文并没有这四个字,上层要能把它和原样命中区分开。
const STRIPPED_CONFIDENCE: f32 = 0.8;

/// 药名规范化前的**确定性剥壳**:真实处方写「盐酸二甲双胍片」「阿托伐他汀钙片」,而
/// 字典按通用名(二甲双胍 / 阿托伐他汀)收录。这里对已 normalize 的词生成候选词干 ——
/// 去前导盐基、去尾部剂型、再去尾部成盐金属字 —— 供 [`normalize`] 在直配未命中时逐个
/// 重试。**候选式、不破坏原词**:某个候选没配上只是跳过,所以「碳酸氢钠」不会被误删成
/// 「碳酸氢」再乱配——两个候选都配不上就整体 miss(诚实,交给上层保留原文)。
fn drug_stem_candidates(norm: &str) -> Vec<String> {
    // 前导成盐酸根(仅去一次)。刻意不含「单硝酸/碳酸氢」这类本身就是药名一部分的。
    const SALT_PREFIX: &[&str] = &[
        "盐酸",
        "硫酸氢",
        "硫酸",
        "苯磺酸",
        "琥珀酸",
        "马来酸",
        "富马酸",
        "酒石酸",
        "氢溴酸",
        "磷酸",
        "醋酸",
        "枸橼酸",
        "甲磺酸",
        "门冬",
    ];
    const FORM_SUFFIX: &[&str] = &[
        "缓释片",
        "控释片",
        "分散片",
        "咀嚼片",
        "泡腾片",
        "肠溶片",
        "口服溶液",
        "口服液",
        "软胶囊",
        "缓释胶囊",
        "肠溶胶囊",
        "注射液",
        "混悬液",
        "干混悬剂",
        "颗粒",
        "胶囊",
        "滴丸",
        "胶丸",
        "散",
        "糖浆",
        "贴片",
        "栓",
        "片",
    ];
    // 尾部成盐(长的排前面:「琥珀酸钠」要先于「钠」被匹配)。
    const SALT_SUFFIX: &[&str] = &[
        "琥珀酸钠",
        "磷酸钠",
        "磺酸钠",
        "氨丁三醇",
        "钙",
        "钠",
        "钾",
        "镁",
    ];

    // 剥前缀:浓度(10%氯化钾注射液)与「注射用」(注射用泮托拉唑钠 → 泮托拉唑钠)。
    let no_pct = norm.trim_start_matches(|c: char| c.is_ascii_digit() || c == '.' || c == '%');
    let head = normalize_term("注射用");
    let stem0 = no_pct.strip_prefix(&head).unwrap_or(no_pct).to_string();

    // 反复去尾部剂型(「…钙片」先去片)。刻意先只去剂型、不去盐前缀:否则「琥珀酸亚铁片」
    // 会被剥成「亚铁」而丢掉本来能直配的「琥珀酸亚铁」。
    let mut form_stripped = stem0.clone();
    while let Some(f) = FORM_SUFFIX
        .iter()
        .find(|f| form_stripped.ends_with(&normalize_term(f)))
    {
        form_stripped.truncate(form_stripped.len() - normalize_term(f).len());
    }

    // 载液:「左氧氟沙星氯化钠注射液」= 药 + 载液,去剂型后再去载液即落到通用名。
    // 载液组合是无穷的(氯化钠/葡萄糖 × 每种药),所以剥壳处理,绝不给字典开条目。
    const CARRIER: &[&str] = &["氯化钠", "葡萄糖"];
    // 候选逐级放宽:①去剂型 ②再去载液 ③再去盐前缀 —— 每级再各出一个「去尾部成盐」的版本。
    let mut bases = vec![stem0, form_stripped.clone()];
    for c in CARRIER {
        if let Some(r) = form_stripped.strip_suffix(&normalize_term(c)) {
            if r.chars().count() > 1 {
                bases.push(r.to_string());
            }
        }
    }
    for p in SALT_PREFIX {
        let pn = normalize_term(p);
        if let Some(r) = form_stripped.strip_prefix(&pn) {
            bases.push(r.to_string());
            break;
        }
    }
    let mut cands: Vec<String> = Vec::new();
    for b in bases {
        if b.chars().count() > 1 && b != norm {
            cands.push(b.clone());
        }
        for s in SALT_SUFFIX {
            let sn = normalize_term(s);
            let Some(shorter) = b.strip_suffix(&sn) else {
                continue;
            };
            if shorter.chars().count() > 1 && shorter != norm {
                cands.push(shorter.to_string());
            }
            break; // 只剥一层成盐
        }
    }
    cands.dedup();
    cands
}

/// 去掉尾部剂量规格:「醋酸泼尼松片5mg」→「醋酸泼尼松片」。处方上药名后面常跟规格,
/// 它不是药名的一部分。返回 `None` 表示没有可去的规格。
fn strip_trailing_dose(s: &str) -> Option<String> {
    // 长的写法排前面,免得「万单位」先被「单位」吃掉。
    const DOSE_UNITS: &[&str] = &[
        "万单位",
        "万iu",
        "单位",
        "mcg",
        "mg",
        "ug",
        "gm",
        "ml",
        "iu",
        "g",
        "u",
        "%",
    ];
    for u in DOSE_UNITS {
        // 取原串末尾同样字符数的后缀 —— 从 s 自己的 char 里取,所以它的字节长度必然落在
        // UTF-8 边界上。**不能**拿 s.to_lowercase() 的字节偏移去切 s:小写化会改变字节长度
        // (「ẞ」3 字节 → 「ß」2 字节,「İ」2 → 3),切出来要么错位要么 panic。
        let n = u.chars().count();
        let tail: String = {
            let mut cs: Vec<char> = s.chars().rev().take(n).collect();
            cs.reverse();
            cs.into_iter().collect()
        };
        if tail.chars().count() < n || tail.to_lowercase() != *u {
            continue;
        }
        let head = &s[..s.len() - tail.len()];
        let stem = head.trim_end_matches(|c: char| c.is_ascii_digit() || c == '.');
        // 必须真去掉了数字(否则「片g」这种误判),且剩余不能为空。
        if stem.len() < head.len() && !stem.is_empty() {
            return Some(stem.to_string());
        }
    }
    None
}

/// 剥掉报告版式的印刷标记:真实报告常在项目名前印 `#`/`*`/`★`/`☆`/`◆`(「重点关注」/
/// 「异常提示」/院内打印惯例),`*` 有时会剥完括号后残留在末尾(如
/// 「γ-谷氨酰转肽酶(γ-GT化学法)*」剥括号后是「…酶*」)。这些标记与项目名本身无关,
/// 但 `normalize` 是精确查表,标记不去掉就整条认不出。返回 `None` 表示没有可剥的标记。
///
/// **尾部刻意不剥 `#`**:血细胞分类计数的字典别名本来就用尾部 `#` 表示「绝对值/计数」
/// 而非「百分比」(`NEUT#`、`LYM#`、`MONO#`…… 见 build_index 建索引时收录的别名),
/// `#` 是这些别名的一部分,剥了会把「NEUT#」错剥成「NEUT」。前缀 `#` 没有这个问题——
/// 词典里没有一条别名以 `#`/`*`/`★`/`☆`/`◆` 开头。
fn strip_report_markers(s: &str) -> Option<String> {
    const LEADING: &[char] = &['#', '*', '★', '☆', '◆'];
    const TRAILING: &[char] = &['*', '★', '☆', '◆'];
    let stripped = s.trim_start_matches(LEADING).trim_end_matches(TRAILING);
    if stripped.chars().count() < s.chars().count() && !stripped.is_empty() {
        Some(stripped.to_string())
    } else {
        None
    }
}

/// 是否是 CJK 表意文字(汉字)。用来把「中文段紧贴 ASCII 段连写」(报告把化验项
/// 中文名和缩写直接印在一起、中间无空格顿号,如「白细胞WBC」「血小板压积PCT」)
/// 从其它 ASCII 标点/希腊字母/数字里分出来——那些整体属于同一个词(见
/// [`term_candidates`] 顶部注释的反例),不该被当成脚本边界切开。
fn is_han(c: char) -> bool {
    matches!(c, '\u{4E00}'..='\u{9FFF}' | '\u{3400}'..='\u{4DBF}')
}

/// 按「汉字段 / 非汉字段」脚本边界把 `s` 切成连续同类字符的段。空白与
/// [`term_candidates`] 里已经处理过的分隔符(顿号、逗号等)在这里当硬边界,
/// 直接丢弃、不并入任何段,好让 `RDW-SD`、`NEU%`、`LYM#` 这类**自带 `-`/`%`/`#`
/// 的缩写整体留在同一段里**——切的是「汉字↔非汉字」的边界,不是 ASCII 内部的
/// 标点。
fn script_runs(s: &str) -> Vec<(bool, String)> {
    const SEPS: [char; 5] = [' ', '\u{3000}', '、', ',', '，'];
    let mut runs: Vec<(bool, String)> = Vec::new();
    let mut cur = String::new();
    let mut cur_han: Option<bool> = None;
    for c in s.chars() {
        if SEPS.contains(&c) {
            if let Some(h) = cur_han.take() {
                runs.push((h, std::mem::take(&mut cur)));
            }
            continue;
        }
        let h = is_han(c);
        match cur_han {
            Some(prev) if prev == h => cur.push(c),
            _ => {
                if let Some(prev) = cur_han {
                    runs.push((prev, std::mem::take(&mut cur)));
                }
                cur_han = Some(h);
                cur.push(c);
            }
        }
    }
    if let Some(h) = cur_han {
        runs.push((h, cur));
    }
    runs
}

/// 「中文段紧贴 ASCII 段连写」的候选:只取**首尾两段**,中间夹的段绝不单独
/// 当候选——多段夹心(「平均红细胞**HB**浓度」)里的中间段多半是词内缩写,不是
/// 独立指标,单独查表容易撞上不相关的词条(见 [`hb_infix_candidate`])。
///
/// 默认中文先——裸 ASCII 短代码常跨领域撞车(`PCT` 既是「血小板压积」也是
/// 「降钙素原」,`LEU` 既关联血 WBC 也是尿白细胞酯酶),中文描述通常无歧义。
///
/// 但 ASCII 段带**限定符**(连字符,或字母掺数字,如 `RDW-SD`、`A2`、`-MB`)时,
/// 裸中文前缀**整个不给**——不是换个顺序试,是压根不当候选:限定符存在本身就
/// 说明这个概念有好几个近亲变体共享同一个中文词根,裸中文词根默认指向的是**另一个**
/// 变体,而不是这一条:
/// - `RDW-SD`(标准差)vs `RDW-CV`(变异系数)是两个不同指标,词典里裸中文
///   「红细胞体积分布宽度」本身默认指向 CV 口径——中文先试会把 RDW-SD 误配成
///   RDW(CV)。
/// - `血红蛋白A2`(血红蛋白电泳的一个组分,词典压根没收)如果只看得懂中文前缀
///   「血红蛋白」,会被顶替成整段血红蛋白浓度——一个看着合理、其实错的临床值。
/// - `肌酸激酶-MB`(本该是 CK-MB 同工酶,词典该走的别名其实是「CK-MB」/
///   「肌酸激酶同工酶MB」,`-MB` 单独查不到)如果放行裸中文前缀「肌酸激酶」兜底,
///   会被误配成完全不同的另一个指标「肌酸激酶」(普通 CK,不是同工酶)。
///
/// 三个例子里,ASCII 段自己能不能查到都不能改变结论:查得到就该让它自己赢
/// (`RDW-SD`);查不到也不该退回去信裸中文(`血红蛋白A2`、`肌酸激酶-MB`)——
/// 宁可连这条都 miss。
///
/// 报告行首常印裸数字序号(「20血小板总数」「3总胆红素」),序号紧贴中文、没有
/// 分隔符,跟这里要切的「中文+缩写」连写长得一样(都是「汉字段紧邻非汉字段」),
/// 但序号不是名字的一部分,也不构成限定符——过滤规则是「ASCII 段必须含字母」,
/// 纯数字段直接放弃整切(见下)。
fn han_ascii_boundary_candidates(s: &str) -> Vec<String> {
    let runs = script_runs(s);
    if runs.len() < 2 {
        return Vec::new();
    }
    let mut boundary: Vec<&(bool, String)> = vec![runs.first().unwrap()];
    let last = runs.last().unwrap();
    if !std::ptr::eq(last, boundary[0]) {
        boundary.push(last);
    }
    let han: Vec<&str> = boundary
        .iter()
        .filter(|r| r.0)
        .map(|r| r.1.as_str())
        .collect();
    let non_han: Vec<&str> = boundary
        .iter()
        .filter(|r| !r.0)
        .map(|r| r.1.as_str())
        .collect();
    let has_letter = |t: &str| t.chars().any(char::is_alphabetic);
    if !non_han.iter().any(|t| has_letter(t)) {
        return Vec::new();
    }
    let has_qualifier = |t: &&str| t.contains('-') || t.chars().any(|c| c.is_ascii_digit());
    if non_han.iter().any(has_qualifier) {
        return non_han.iter().map(|t| t.to_string()).collect();
    }
    han.iter()
        .chain(non_han.iter())
        .map(|t| t.to_string())
        .collect()
}

/// 「中文—HB—中文」夹心(`平均红细胞HB浓度` = MCHC,`平均红细胞HB含量` = MCH):
/// `HB` 是「血红蛋白」在报告里的惯用中缀缩写,但**只有前后都是中文时才展开替换、
/// 重组整串再查表**——绝不把裸 `HB` 当独立候选,否则会误配到「血红蛋白」本身
/// (`Hb` 是 hgb 条目的别名),而这里整体说的是红细胞的平均血红蛋白浓度/含量,
/// 是完全不同的指标。重组出的整串仍然要走跟其它候选一样的精确查表,不是新开
/// 一条模糊路径。
fn hb_infix_candidate(s: &str) -> Option<String> {
    let runs = script_runs(s);
    let [(h0, r0), (hm, rm), (h2, r2)] = runs.as_slice() else {
        return None;
    };
    if *h0 && *h2 && !hm && rm.eq_ignore_ascii_case("hb") {
        Some(format!("{r0}血红蛋白{r2}"))
    } else {
        None
    }
}

/// 术语名**候选拆分**(提取层调用,不在 [`normalize`] 里跑):真实报告/处方写
/// 「甘油三酯 TG」「肌酐 Cr(Scr)」「甲泼尼龙片(美卓乐)4mg」——整串精确查表必 miss,
/// 拆开后各自查即命中。
///
/// 产出候选:去括号后的主体 → 主体按空格/斜杠/顿号切出的 token → 括号内内容切出的
/// token(括号里常是同义缩写或商品名)→ 每个候选再去掉尾部剂量规格。**纯确定性,不是
/// 模型**。调用方按顺序拿每个候选去 [`normalize`](药名的盐基/剂型剥壳在那儿做),第一个
/// 命中即用;全不命中就是 miss(诚实,上层保留原文)。
///
/// [`normalize`] 本身**刻意不做**这件事:它是单词查表,拆分是提取层的职责(design §6)。
pub fn term_candidates(name: &str) -> Vec<String> {
    let is_open = |c: char| matches!(c, '(' | '（' | '[' | '【');
    let is_close = |c: char| matches!(c, ')' | '）' | ']' | '】');
    let (mut stripped, mut inner_all) = (String::new(), Vec::<String>::new());
    let mut inner = String::new();
    let mut depth = 0i32;
    for c in name.chars() {
        if is_open(c) {
            depth += 1;
        } else if is_close(c) {
            depth -= 1;
            if depth <= 0 && !inner.trim().is_empty() {
                inner_all.push(inner.trim().to_string());
                inner.clear();
            }
        } else if depth >= 1 {
            inner.push(c);
        } else {
            stripped.push(c);
        }
    }
    // 刻意**不按斜杠切**:化验名里的「/」多半是比值本身(尿白蛋白/肌酐比值、AST/ALT),
    // 切开会先命中分子(尿白蛋白)而丢掉真正的项(ACR)。
    const SEPS: [char; 5] = [' ', '\u{3000}', '、', ',', '，'];
    // OCR 常把右括号丢掉(「(肌酐」):残留的括号内内容也收进候选,否则整段被吞掉必 miss。
    if !inner.trim().is_empty() {
        inner_all.push(inner.trim().to_string());
    }
    // 候选顺序:原串 → 去括号主体 → 各自的 token → **括号内内容放最后兜底**。
    // 括号里的裸缩写常与别的项撞车(尿常规「尿红细胞计数(RBC)」的 RBC = 血 RBC;
    // 「血小板压积(PCT)」的 PCT = 降钙素原),优先用它会造成**误配**——比 miss 危险得多。
    let mut cands: Vec<String> = vec![name.trim().to_string(), stripped.trim().to_string()];
    for src in [name, &stripped] {
        for t in src.split(SEPS) {
            let t = t.trim();
            if !t.is_empty() {
                cands.push(t.to_string());
            }
        }
    }
    for blk in &inner_all {
        for t in blk.split(SEPS) {
            let t = t.trim();
            if !t.is_empty() {
                cands.push(t.to_string());
            }
        }
    }
    // 每个候选再补一个「去掉报告版式印刷标记」的版本(#/*/★/☆/◆,见
    // strip_report_markers 文档)。放在去规格之前,好让「★白细胞计数5mg」这类
    // 标记+规格叠加的候选也能在下一步被去规格补全。
    for i in 0..cands.len() {
        if let Some(stem) = strip_report_markers(&cands[i]) {
            cands.push(stem);
        }
    }
    // 每个候选再补一个「去掉尾部规格」的版本(处方:醋酸泼尼松片5mg)。
    for i in 0..cands.len() {
        if let Some(stem) = strip_trailing_dose(&cands[i]) {
            cands.push(stem);
        }
    }
    // 「中文段紧贴 ASCII 段连写」兜底:放在最后,前面任何一步已经产出的命中都
    // 优先于它。只在**去括号后的主体**(`stripped`)和**括号内内容**
    // (`inner_all`)上切——不用带括号的原串 `name`,括号本身是非汉字字符,会把
    // 「(」「)」跟相邻的 ASCII 缩写粘成一段,产出一堆查不到、纯浪费的候选。
    for c in han_ascii_boundary_candidates(&stripped) {
        cands.push(c);
    }
    for blk in &inner_all {
        for c in han_ascii_boundary_candidates(blk) {
            cands.push(c);
        }
    }
    if let Some(c) = hb_infix_candidate(&stripped) {
        cands.push(c);
    }
    cands.retain(|c| !c.is_empty());
    cands.dedup();
    cands
}

/// 单位**记法折叠**(纯记法,不碰语义):报告写 `×10^9/L`、`10E9/L`、`μmol/L`、全角字符,
/// 字典按 UCUM 写 `10*9/L`、`umol/L` —— 同一个单位的不同写法。字典行和报告单位都过这个
/// 函数再比较,记法差异就不再是 miss。
///
/// **刻意不折大小写**:`mU/L`(毫单位)≠ `MU/L`(兆单位),折了就差 6 个数量级。真正的
/// 量纲差异只能靠字典 `units[]` 里的显式换算,不能靠字符串猜。
pub fn normalize_unit(raw: &str) -> String {
    let mut s = String::with_capacity(raw.len());
    for ch in raw.chars() {
        let ch = to_halfwidth(ch);
        if ch.is_whitespace() {
            continue;
        }
        s.push(match ch {
            'µ' | 'μ' => 'u',
            '×' | '✕' => 'x',
            '^' => '*',
            // 上标数字(报告写 1.73m²、mm³)→ 普通数字。
            '²' => '2',
            '³' => '3',
            c => c,
        });
    }
    // 科学计数写法 10E9 / 10e9 → UCUM 10*9;再去掉前导乘号(×10*9/L → 10*9/L)。
    let s = s.replace("10E", "10*").replace("10e", "10*");
    s.strip_prefix(['x', 'X']).unwrap_or(&s).to_string()
}

/// Map a single candidate term to its canonical concept. Returns `None` on no
/// hit. This is a lookup, not a full-text scan — locating terms in free text is
/// the extraction layer's job (design §6).
///
/// An exact (normalized) alias hit yields `confidence == 1.0`; an
/// `ocr_confusions` hit yields `confidence == 0.5`. If a raw drug term
/// (`盐酸二甲双胍片`) doesn't match directly, deterministic salt/form stripping is
/// retried and, on a **drug** hit, returned at [`STRIPPED_CONFIDENCE`] (0.8) —— 剥壳是推断,
/// 不能和原样命中同等信任。
pub fn normalize(raw_term: &str) -> Option<Match> {
    let norm = normalize_term(raw_term);
    if norm.is_empty() {
        return None;
    }
    let idx = index();
    if let Some(hit) = idx.aliases.get(&norm) {
        return Some(idx.to_match(hit, 1.0));
    }
    if let Some(hit) = idx.confusions.get(&norm) {
        return Some(idx.to_match(hit, 0.5));
    }
    // 药名剥壳兜底:去盐/剂型后重试,只在 drug 命名空间里查(仍确定性、可核对)。
    for cand in drug_stem_candidates(&norm) {
        if let Some(hit) = idx.drug_aliases.get(&cand) {
            return Some(idx.to_match(hit, STRIPPED_CONFIDENCE));
        }
    }
    None
}

/// 这个条目认不认这个单位(记法折叠后比较 canonical_unit 与 units[])。
fn entry_accepts_unit(entry: &Entry, unit: &str) -> bool {
    let u = normalize_unit(unit);
    entry.canonical_unit.as_deref().map(normalize_unit) == Some(u.clone())
        || entry.units.iter().any(|r| normalize_unit(&r.unit) == u)
}

/// 模糊匹配置信度:低于 OCR 混淆表命中(0.5,人工核实过的已知误读),因为这是
/// **推算**出来的近邻,不是任何人核对过的对应关系。仍高于 0(不是无意义的猜),
/// 上层可据此单独路由(比如比 confusions 命中更强烈地提示人工复核)。
const FUZZY_CONFIDENCE: f32 = 0.4;

/// 模糊匹配的最短名字长度(归一化后字符数)。**3 字及以下永不模糊**——诊断样本
/// 里过敏原/同类项套餐的近形词碰撞(`牛奶`→`小麦`、`猫上皮`→`狗上皮`、
/// `牛肉`/`羊肉`→`士肉`)几乎全落在这个长度区间:字数太少,字形上根本分不开
/// "这是同一个词的误读" 和 "这是同一张套餐单上另一个词"。短名字只走精确匹配 /
/// OCR 混淆表,查不到就诚实 miss——比错配安全。
const FUZZY_MIN_LEN: usize = 4;

/// 按归一化后字符数分档的编辑距离上限。**故意统一收在 1**,没有随长度放宽——
/// 第一版按诊断表的相对距离放宽到 2~3 字后实测(loop/fuzzy 报告)踩了一类没预料到
/// 的坑:血常规分类计数/百分比一族(中性/淋巴/单核/嗜酸性/嗜碱性粒细胞×比率/
/// 百分比/计数)彼此共享极长的公共后缀("…细胞比率"/"…细胞计数"),只在开头的
/// 分类字上有 1~2 字差——`嗜酸性`→`中性`编辑距离恰好是 2,`单核`→`多核`恰好是 1,
/// 但两者是**完全不同的临床概念**,不是同一个词的误读。放宽到 2 字直接把
/// "嗜酸性粒细胞比率" 错配成 neut_pct、把"多核细胞比率"错配成 mono_pct,把错配率
/// 从 13.0% 推到 13.7%,破了红线。收紧到统一 1 字之后这类整词替换基本挡住了
/// (`单/多`这种仍是 1 字差的残余风险,靠下面的数字前缀护栏和歧义拒绝兜底,
/// 详见报告"剩余天花板"一节)。
fn fuzzy_max_distance(len: usize) -> usize {
    if len < FUZZY_MIN_LEN {
        0 // 从不会用到:调用方已用 FUZZY_MIN_LEN 挡在前面。
    } else {
        1
    }
}

/// 提取字符串里的 ASCII 数字子串(按出现顺序拼接,不含分隔符)。用于
/// [`fuzzy_lookup`] 的"数字前缀/编号必须原样一致"护栏。
fn digit_run(s: &str) -> String {
    s.chars().filter(char::is_ascii_digit).collect()
}

/// 截断前缀匹配允许被切掉的最长尾巴(字符数)。词典里常见后缀
/// (百分比/绝对值/比率/计数……)大多 2~4 字,留一点余量到 4;再长就该走普通
/// 编辑距离而不是"当作截断"——一个 4 字查询前缀配一条 12 字别名没有意义。
const TRUNCATION_MAX_EXTRA: usize = 4;

/// 字符级 Levenshtein 距离。**必须按 `char` 不按字节**——中文字符是多字节
/// UTF-8,按字节比较会把"差一个汉字"算成"差三个字节",阈值全部失真。
fn edit_distance(a: &[char], b: &[char]) -> usize {
    let (n, m) = (a.len(), b.len());
    if n == 0 {
        return m;
    }
    if m == 0 {
        return n;
    }
    let mut prev: Vec<usize> = (0..=m).collect();
    let mut cur = vec![0usize; m + 1];
    for i in 1..=n {
        cur[0] = i;
        for (j, &bc) in b.iter().enumerate().map(|(j, c)| (j + 1, c)) {
            let cost = usize::from(a[i - 1] != bc);
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[m]
}

/// 词典范围内的模糊查找,`resolve` 精确路径(`normalize` 的直配/OCR混淆表/药名
/// 剥壳)全部 miss 之后才会走到这里。**只从这里调用,不接入 `normalize` /
/// `normalize_drug`**:那两个是别的调用方(药名剥壳候选、`coverage` 覆盖率统计、
/// 处方解析)依赖"精确查表"这条不变式的地方,模糊化会悄悄改变它们的语义。
///
/// 策略(宁可漏不可错——见 loop/fuzzy 报告的诊断):
/// 1. **短名不模糊**([`FUZZY_MIN_LEN`]):见该常量文档。
/// 2. **编辑距离上限**([`fuzzy_max_distance`])。
/// 3. **数字前缀护栏**:query 和候选别名里的数字子串(按出现顺序拼接)必须完全
///    相同才允许进入距离比较。医学名词里的数字几乎全是**编号/亚型**而不是易读错
///    的笔画(`IL-2`≠`IL-6`、`CD4`≠`CD8`、`HPV16`≠`HPV18`、维生素`B6`≠`B12`)——
///    这类词一位数字之差就是完全不同的概念,不是 OCR 手误,不能算进"1 字编辑距离"
///    的容错预算里。（真实诊断中 `IL-2(T-N)` 被错配成 il6 就是这类事故,数字不
///    一致直接挡住。)
/// 4. **截断前缀优先于编辑距离**([`TRUNCATION_MAX_EXTRA`]):版式/表格列宽把名字
///    尾巴切掉(`中性粒细胞百` = "中性粒细胞百分比" 被切掉"分比")是比"某个汉字被
///    识别错"更常见、也更好判断的失败模式——**query 是且只是某条别名的前缀**这件
///    事本身不需要猜任何字形。它因此比同长度的编辑距离候选更可信,哪怕两者数值
///    上都"距离很近":`中性粒细胞百` 到 neut_count 的别名`中性粒细胞数`只差 1 字
///    (`百`→`数`,纯属两个同族词碰巧同长度还差一个通用后缀字的巧合),但到
///    neut_pct 的`中性粒细胞百分比`是**真前缀关系**——后者才是真相。前缀候选按
///    "有效距离 0" 参与全局最小距离/歧义竞争,不与编辑距离候选混着比大小。
/// 5. **歧义拒绝**:全词典范围内,若最小距离被两个以上不同条目打平,不猜——除非
///    本行带着单位,且单位能把打平的候选唯一筛剩一个(数值侧证据消解名字侧歧义)。
/// 6. **只在化验/体征命名空间找**(跳过 `Category::Drug`):`resolve` 是化验报告单
///    语境,药名撞进来只有风险没有收益。
fn fuzzy_lookup(name: &str, unit: Option<&str>) -> Option<Match> {
    let norm = normalize_term(name);
    let len = norm.chars().count();
    if len < FUZZY_MIN_LEN {
        return None;
    }
    let max_dist = fuzzy_max_distance(len);
    let norm_chars: Vec<char> = norm.chars().collect();
    let norm_digits = digit_run(&norm);
    let idx = index();

    // 每个条目在其所有别名里的最近距离(达到阈值才收;截断前缀记作 0)。
    let mut best_per_entry: Vec<(usize, String, usize)> = Vec::new();
    for (entry_idx, entry) in idx.entries.iter().enumerate() {
        if entry.category == Category::Drug {
            continue;
        }
        let mut best: Option<(String, usize)> = None;
        for alias in &entry.aliases {
            let a_norm = normalize_term(alias);
            let a_len = a_norm.chars().count();
            // query 是这条别名的真前缀(别名更长、被切掉的尾巴不太长)——当截断处理,
            // 不进普通编辑距离比较(见上文文档)。
            let is_truncation =
                a_len > len && a_len - len <= TRUNCATION_MAX_EXTRA && a_norm.starts_with(&norm);
            if !is_truncation && a_len.abs_diff(len) > max_dist {
                // 长度差本身已经超阈值,距离必然超阈值——省一次 DP。
                continue;
            }
            // 数字前缀护栏:两边数字不完全一致就不是同一个编号/亚型,直接跳过。
            if digit_run(&a_norm) != norm_digits {
                continue;
            }
            let d = if is_truncation {
                0
            } else {
                let a_chars: Vec<char> = a_norm.chars().collect();
                let d = edit_distance(&norm_chars, &a_chars);
                if d > max_dist {
                    continue;
                }
                d
            };
            if best.as_ref().map(|(_, bd)| d < *bd).unwrap_or(true) {
                best = Some((alias.clone(), d));
            }
        }
        if let Some((alias, d)) = best {
            best_per_entry.push((entry_idx, alias, d));
        }
    }
    if best_per_entry.is_empty() {
        return None;
    }
    let min_dist = best_per_entry.iter().map(|(_, _, d)| *d).min()?;
    let tied: Vec<&(usize, String, usize)> = best_per_entry
        .iter()
        .filter(|(_, _, d)| *d == min_dist)
        .collect();

    let winner = if tied.len() == 1 {
        tied[0]
    } else {
        // 歧义:只有单位能唯一裁决才接受,否则不猜。
        let u = unit.map(str::trim).filter(|u| !u.is_empty())?;
        let mut accepting = tied
            .iter()
            .filter(|(entry_idx, _, _)| entry_accepts_unit(&idx.entries[*entry_idx], u));
        let only = accepting.next()?;
        if accepting.next().is_some() {
            return None; // 单位还是分不开——仍然歧义。
        }
        only
    };

    let hit = AliasHit {
        entry_idx: winner.0,
        alias: winner.1.clone(),
    };
    Some(idx.to_match(&hit, FUZZY_CONFIDENCE))
}

/// 报告一行(项名 + 单位)→ 概念。**提取层该用的入口**,不是 [`normalize`]。
///
/// 拆候选后**不是「第一个命中即用」** —— 那样结果取决于候选顺序,很脆:
/// 「血小板压积(PCT)」的 PCT 会撞降钙素原,「尿红细胞计数(RBC)」的 RBC 会撞血 RBC。
/// 这里收集**所有**候选的命中,按证据择优:
///
/// 1. **单位证据优先**:报告行本来就带单位,而它是确定性的判别器 ——
///    `红细胞分布宽度(RDW-SD)` 的 `fL` vs RDW-CV 的 `%`;`血小板压积` 的 `%` vs
///    降钙素原的 `ng/mL`;`尿红细胞` 的 `/uL` vs 血 RBC 的 `10*12/L`。
/// 2. 然后比置信度(精确 1.0 > 剥壳 0.8 > OCR 混淆 0.5)。
/// 3. 再取**匹配最长**的(maximal munch):更长的别名 = 更具体的概念。
/// 4. 全平手才按候选顺序 —— 顺序退化成 tie-break,不再是正确性的支点。
///
/// 精确路径(含候选拆分)全部 miss 时,再对**主体候选**(原串 + 去括号主体,
/// [`term_candidates`] 输出的前两项)试一次 [`fuzzy_lookup`]——只试这两个,不对
/// 拆分出的短 token / 括号内裸缩写模糊,那些片段模糊匹配风险远大于收益(见
/// `fuzzy_lookup` 文档的歧义拒绝一节)。
pub fn resolve(name: &str, unit: Option<&str>) -> Option<Match> {
    let cands = term_candidates(name);
    let hits: Vec<Match> = cands.iter().filter_map(|c| normalize(c)).collect();
    if !hits.is_empty() {
        return pick_best(hits, unit);
    }
    cands.iter().take(2).find_map(|c| fuzzy_lookup(c, unit))
}

/// 处方语境的 [`resolve`]:只在 drug 命名空间里择优(处方没有单位可用作证据)。
pub fn resolve_drug(name: &str) -> Option<Match> {
    let hits: Vec<Match> = term_candidates(name)
        .iter()
        .filter_map(|c| normalize_drug(c))
        .collect();
    pick_best(hits, None)
}

/// 从若干候选命中里按证据择优。`max_by_key` 在平手时保留**最后**一个,所以先反转,
/// 让平手回落到候选顺序里**最靠前**的那个。
fn pick_best(hits: Vec<Match>, unit: Option<&str>) -> Option<Match> {
    let entries = dictionary_entries();
    let unit = unit.map(str::trim).filter(|u| !u.is_empty());
    hits.into_iter().rev().max_by_key(|m| {
        let accepts = unit.is_some_and(|u| {
            entries
                .iter()
                .find(|e| e.key == m.key)
                .is_some_and(|e| entry_accepts_unit(e, u))
        });
        (
            accepts,
            (m.confidence * 100.0) as u32,
            m.matched_alias.chars().count(),
        )
    })
}

/// 处方语境的 [`normalize`]:**只在 drug 命名空间里查**。同名跨类别时(「叶酸」「氢化可的松」
/// 既是化验也是药),提取层解析的是处方就该用这个,否则会被化验项抢走。
/// 先整串直配,再走确定性剥壳(前缀「注射用」/ 盐基 / 剂型 / 尾部成盐)。
pub fn normalize_drug(raw_term: &str) -> Option<Match> {
    let norm = normalize_term(raw_term);
    if norm.is_empty() {
        return None;
    }
    let idx = index();
    if let Some(hit) = idx.drug_aliases.get(&norm) {
        return Some(idx.to_match(hit, 1.0));
    }
    if let Some(hit) = idx.drug_confusions.get(&norm) {
        return Some(idx.to_match(hit, 0.5));
    }
    drug_stem_candidates(&norm)
        .iter()
        .find_map(|c| idx.drug_aliases.get(c))
        .map(|hit| idx.to_match(hit, STRIPPED_CONFIDENCE))
}

/// Read-only access to the parsed dictionary (entries), for consumers that need
/// to enumerate concepts (e.g. entity search auto-complete).
pub fn dictionary_entries() -> &'static [Entry] {
    &index().entries
}

/// Fixed display order for the lab-panel catalog (检验大类:血常规/肝功能/…) —
/// mirrors a Chinese lab report's project-group headers, curated in
/// `panel_methodology.md`. A test below asserts this exactly matches the set of
/// distinct `panel` values actually present in `dictionary.json`, so a typo or
/// a forgotten/renamed panel can't silently drift the two apart.
pub const PANEL_CATALOG: &[&str] = &[
    // 自测项排在最前:手动录入的血压/心率/体重是用户**自己天天在看**的东西,
    // 而化验大类是隔几个月才来一次的。chip 是横向滚动的,谁在前谁被看见。
    "生命体征",
    "体格测量",
    "血常规",
    "尿液",
    "肝功能",
    "肾功能",
    "血糖",
    "血脂",
    "电解质",
    "甲状腺功能",
    "凝血",
    "心肌标志物",
    "炎症/感染",
    "肿瘤标志物",
    "风湿免疫",
    "性激素",
];

/// Which lab panel a normalized analyte `key` belongs to (e.g.
/// `panel_for("creatinine") == Some("肾功能")`). `None` when `key` doesn't
/// resolve to a dictionary entry, or when the entry has no `panel` — most
/// commonly a specialty/low-frequency lab that doesn't cleanly fit one of the
/// curated panels (see `panel_methodology.md`'s "留空" section). Callers should
/// treat `None` as "uncategorized", not as an error.
pub fn panel_for(key: &str) -> Option<&'static str> {
    dictionary_entries()
        .iter()
        .find(|e| e.key == key)
        .and_then(|e| e.panel.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every analyte/vital/drug key required by docs/015 §3.5. The dictionary
    /// may add siblings, but must never drop one of these.
    const REQUIRED_KEYS: &[&str] = &[
        // labs: renal, glucose, lipids, liver, CBC, thyroid
        "creatinine",
        "egfr",
        "urea",
        "uric_acid",
        "glucose",
        "hba1c",
        "cholesterol",
        "ldl",
        "hdl",
        "triglycerides",
        "alt",
        "ast",
        "tbil",
        "albumin",
        "wbc",
        "hgb",
        "plt",
        "neut_pct",
        "tsh",
        // vitals
        "bp_systolic",
        "bp_diastolic",
        "heart_rate",
        "body_weight",
        "bmi",
        // drugs named in §3.5
        "metformin",
        "glimepiride",
        "acarbose",
        "empagliflozin",
        "semaglutide",
        "insulin_glargine",
        "insulin_aspart",
        "valsartan",
        "amlodipine",
        "metoprolol",
        "hydrochlorothiazide",
        "perindopril",
        "atorvastatin",
        "rosuvastatin",
        "ezetimibe",
        "aspirin",
        "clopidogrel",
        "warfarin",
        "rivaroxaban",
        "allopurinol",
        "levothyroxine",
        "pantoprazole",
    ];

    #[test]
    fn parse_dictionary() {
        let dict: Dictionary = serde_json::from_str(DICTIONARY_JSON).expect("valid dictionary");
        assert!(!dict.version.is_empty());
        assert!(dict.entries.len() >= 50, "unexpectedly few entries");
    }

    #[test]
    fn alias_hits_map_to_same_key() {
        // 谷丙转氨酶 / ALT / GPT / SGPT -> alt
        for t in ["谷丙转氨酶", "ALT", "GPT", "SGPT"] {
            let m = normalize(t).unwrap_or_else(|| panic!("no match for {t}"));
            assert_eq!(m.key, "alt", "term {t}");
            assert_eq!(m.confidence, 1.0);
            assert_eq!(m.category, Category::Lab);
        }
        // 肌酐 / 血肌酐 / Cr / SCr -> creatinine
        for t in ["肌酐", "血肌酐", "Cr", "SCr"] {
            let m = normalize(t).unwrap_or_else(|| panic!("no match for {t}"));
            assert_eq!(m.key, "creatinine", "term {t}");
            assert_eq!(m.confidence, 1.0);
        }
    }

    #[test]
    fn normalization_case_fullwidth_and_split() {
        // full-width ＡＬＴ -> alt
        assert_eq!(normalize("ＡＬＴ").unwrap().key, "alt");
        // lowercase crea -> creatinine
        assert_eq!(normalize("crea").unwrap().key, "creatinine");
        // OCR-split 肌 酐 (internal space stripped) -> creatinine
        assert_eq!(normalize("肌 酐").unwrap().key, "creatinine");
        // full-width ideographic space also stripped
        assert_eq!(normalize("肌\u{3000}酐").unwrap().key, "creatinine");
    }

    #[test]
    fn ocr_confusion_hits_are_low_confidence() {
        let m = normalize("肌研").expect("ocr confusion should match");
        assert_eq!(m.key, "creatinine");
        assert_eq!(m.confidence, 0.5);
        assert_eq!(m.matched_alias, "肌研");
    }

    #[test]
    fn miss_returns_none() {
        assert!(normalize("完全不是术语").is_none());
        assert!(normalize("").is_none());
        assert!(normalize("   ").is_none());
    }

    #[test]
    fn drug_candidates_handle_prescription_writing() {
        // 处方真实写法:规格、商品名括号、复方 —— 拆候选后再剥壳即命中。
        let hit = |name: &str| {
            term_candidates(name)
                .iter()
                .find_map(|c| normalize(c))
                .unwrap_or_else(|| panic!("no candidate hit for {name}"))
                .key
        };
        assert_eq!(hit("醋酸泼尼松片 5mg"), "prednisone");
        assert_eq!(hit("甲泼尼龙片(美卓乐)4mg"), "methylprednisolone");
        assert_eq!(hit("硫酸羟氯喹片(纷乐)0.1g"), "hydroxychloroquine");
        // 规格不会把药名本身吃掉:剥出的候选仍是完整通用名。
        assert!(term_candidates("醋酸泼尼松片5mg").contains(&"醋酸泼尼松片".to_string()));
    }

    #[test]
    fn resolve_uses_unit_evidence_to_break_ambiguity() {
        // 同一个项名能命中两个概念时,报告行里的**单位**是确定性的判别器。
        // 这些以前全靠候选顺序碰运气 —— 顺次试到哪个算哪个,排错一次就是临床误配。
        let cases: &[(&str, &str, &str)] = &[
            // 括号里的裸缩写会撞别的项:PCT 撞降钙素原、RBC 撞血 RBC —— 单位把它们劈开。
            ("血小板压积(PCT)", "%", "plateletcrit"),
            ("尿红细胞计数(RBC)", "/uL", "urine_rbc_count"),
            ("尿白细胞计数(WBC)", "/uL", "urine_wbc_count"),
            // 主体是更泛的名字(红细胞分布宽度 = CV),括号里的 SD 才是本行的项:
            // 单位 fL(SD,绝对值)vs %(CV,变异系数)。
            ("红细胞分布宽度(RDW-SD)", "fL", "rdw_sd"),
            ("红细胞分布宽度(RDW-CV)", "%", "rdw"),
        ];
        for (name, unit, key) in cases {
            let m = resolve(name, Some(unit)).unwrap_or_else(|| panic!("no hit for {name}"));
            assert_eq!(m.key, *key, "{name} [{unit}]");
        }
        // 没有单位时退回最长匹配(maximal munch):主体比括号内的裸缩写更具体。
        assert_eq!(
            resolve("血小板压积(PCT)", None).unwrap().key,
            "plateletcrit"
        );
        // 单位对不上任何候选 → 不硬套,仍按置信度/长度择优,不会因此 miss。
        assert!(resolve("血小板压积(PCT)", Some("荒谬单位")).is_some());
    }

    #[test]
    fn resolve_fuzzy_matches_ocr_corrupted_names() {
        // 精确路径全部 miss 之后,`resolve` 才会退到模糊路径 —— 单字 OCR 误读、
        // 截断都应该救回来,且置信度必须低于精确/剥壳/OCR混淆表。
        let cases: &[(&str, &str)] = &[
            // 单字形近误读(非词典已收录的 ocr_confusions)。"肌酐"本身只有 2 字,
            // 低于模糊匹配的最短长度门槛,所以用 4 字的"血清肌酐"别名来测。
            ("血清肌配", "creatinine"),
            // 版式截断(表格列宽切掉尾巴)—— 前缀关系,不是编辑距离。
            ("中性粒细胞百", "neut_pct"),
            ("嗜酸性粒细胞绝对", "eos_count"),
        ];
        for (raw, key) in cases {
            let m = resolve(raw, None).unwrap_or_else(|| panic!("no fuzzy hit for {raw}"));
            assert_eq!(m.key, *key, "{raw}");
            assert_eq!(
                m.confidence, FUZZY_CONFIDENCE,
                "{raw} should be a fuzzy hit"
            );
        }
    }

    #[test]
    fn resolve_fuzzy_never_matches_short_names() {
        // 3 字及以下永不模糊 —— 过敏原/同类套餐的近形词碰撞几乎全落在这个区间
        // (`牛奶`≠`小麦`,`猫上皮`≠`狗上皮`),字形分不开就该老实 miss,不能猜。
        assert!(resolve("牛奶", None).is_none());
        assert!(resolve("猫上皮", None).is_none());
    }

    #[test]
    fn resolve_fuzzy_rejects_digit_mismatch() {
        // 数字前缀护栏:白细胞介素家族靠数字区分亚型(IL-2 ≠ IL-6),一位数字之差
        // 是完全不同的概念,不能被当成"1 字编辑距离"的容错。
        assert!(resolve("IL-2", Some("pg/mL")).is_none());
        // 数字一致时模糊仍然工作(截断/误读救回同一个编号)。
        assert_eq!(resolve("IL-6单", None).unwrap().key, "il6");
    }

    #[test]
    fn resolve_fuzzy_rejects_ambiguous_ties() {
        // 嗜酸性粒细胞比率(eos_pct)和嗜碱性粒细胞比率(baso_pct)只在"酸/碱"一字
        // 上不同,其余共享同一个模板。一个把这个字读花了的查询到两条别名的编辑
        // 距离一样近(都是 1),而且两个条目都用 `%` —— 单位也分不开,必须拒绝
        // 而不是随便猜一个。
        assert!(resolve("嗜厂性粒细胞比率", None).is_none());
        assert!(resolve("嗜厂性粒细胞比率", Some("%")).is_none());
    }

    #[test]
    fn resolve_drug_picks_longest_match() {
        // maximal munch:更长的别名 = 更具体的药。「地氯雷他定片」不该被 5 字的
        // 「氯雷他定」抢走(那是**另一个药**)。
        assert_eq!(
            resolve_drug("地氯雷他定片 5mg").unwrap().key,
            "desloratadine"
        );
        assert_eq!(resolve_drug("氯雷他定片 10mg").unwrap().key, "loratadine");
        assert_eq!(
            resolve_drug("单硝酸异山梨酯缓释片 60mg").unwrap().key,
            "isosorbide_mononitrate"
        );
    }

    #[test]
    fn carrier_strip_never_swaps_one_drug_for_another() {
        // 载液剥离的边界:带钠的葡萄糖氯化钠 ≠ 不带钠的葡萄糖注射液,复方氯化钠 ≠ 「复方」。
        // 剥壳只能在**整串查不到**时才放宽,顺序错了就是临床误配(病人多输/少输一份钠)。
        assert_eq!(
            normalize_drug("葡萄糖氯化钠注射液").unwrap().key,
            "glucose_sodium_chloride"
        );
        assert_eq!(
            normalize_drug("复方氯化钠注射液").unwrap().key,
            "compound_sodium_chloride"
        );
        // 真正的「药 + 载液」才剥到通用名。
        assert_eq!(
            normalize_drug("左氧氟沙星氯化钠注射液").unwrap().key,
            "levofloxacin"
        );
    }

    #[test]
    fn stripped_match_is_not_full_confidence() {
        // 剥壳是**推断**:原文写的是「盐酸二甲双胍片」,字典命中的是「二甲双胍」。
        // 上层必须能把它和原样精确命中区分开(否则 OCR 掉一个字导致的换药无从察觉)。
        assert_eq!(normalize("盐酸二甲双胍片").unwrap().confidence, 0.8);
        assert_eq!(normalize_drug("注射用泮托拉唑钠").unwrap().confidence, 0.8);
        // 原样命中仍是 1.0。
        assert_eq!(normalize("二甲双胍").unwrap().confidence, 1.0);
        assert_eq!(normalize_drug("二甲双胍").unwrap().confidence, 1.0);
    }

    #[test]
    fn fuzz_random_input_never_panics() {
        // 硬编码的敌意串只能挡住已知的坑;随机 fuzz 才挡得住下一个切片 bug。
        // 用固定种子的 xorshift(可复现,无外部依赖)。
        const ALPHABET: &[char] = &[
            'ẞ', 'İ', 'K', 'Ω', 'ǅ', 'µ', 'μ', '×', '^', '²', '％', 'Ａ', '（', '）', '(', ')',
            '[', ']', '、', '/', ' ', '\u{3000}', '\u{200b}', '\u{0301}', '🩺', '肌', '酐', '片',
            '钠', '注', '射', '用', '5', '0', '.', '%', 'm', 'g', 'L', 'u', '万', '单', '位',
        ];
        let mut state: u64 = 0x9E3779B97F4A7C15;
        let mut next = || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for _ in 0..20_000 {
            let len = (next() % 24) as usize;
            let s: String = (0..len)
                .map(|_| ALPHABET[(next() as usize) % ALPHABET.len()])
                .collect();
            let _ = normalize(&s);
            let _ = normalize_drug(&s);
            let _ = normalize_unit(&s);
            for c in term_candidates(&s) {
                let _ = normalize(&c);
                let _ = normalize_drug(&c);
            }
        }
    }

    #[test]
    fn hostile_input_never_panics() {
        // 输入来自 OCR 出来的病历文本 = 不可信。任何输入都只能 miss,不能 panic(panic = DoS)。
        // 「ẞ5mg」曾真的崩过:小写化改变字节长度(ẞ 3 字节 → ß 2 字节),按 lowercase 的偏移
        // 切原串会切在 UTF-8 字符中间。
        let hostile = [
            "ẞ5mg",
            "İ5mg",
            "ẞẞ5mg",
            "İ1g",
            "ǅ5ml",
            "5mg",
            "%",
            "0.5",
            "mg",
            "万单位",
            "(((",
            ")))",
            "（（（",
            "()",
            "（）",
            "、、、",
            "   ",
            "",
            "\u{200b}",
            "🩺5mg",
            "肌酐\u{0301}",
            "10%",
            "%%%",
            "注射用",
            "注射用片",
            "钠",
            "片",
        ];
        for h in hostile {
            let _ = normalize(h);
            let _ = normalize_drug(h);
            let _ = normalize_unit(h);
            for c in term_candidates(h) {
                let _ = normalize(&c);
                let _ = normalize_drug(&c);
            }
        }
        // 超长串也不能崩(也别指数爆炸)。
        let long_paren = "(".repeat(5_000) + &"肌酐 5mg ".repeat(2_000);
        let _ = term_candidates(&long_paren);
        let _ = normalize(&long_paren);
    }

    #[test]
    fn strips_salt_and_dosage_form_to_ingredient() {
        // 真实处方写法(盐基 + 通用名 + 剂型)→ 剥壳后命中通用名。
        assert_eq!(normalize("盐酸二甲双胍片").unwrap().key, "metformin");
        assert_eq!(normalize("琥珀酸美托洛尔缓释片").unwrap().key, "metoprolol");
        assert_eq!(normalize("苯磺酸氨氯地平片").unwrap().key, "amlodipine");
        // 「…钙片」先去剂型再去成盐金属字。
        assert_eq!(normalize("阿托伐他汀钙片").unwrap().key, "atorvastatin");
        // 剥壳到通用名(碳酸氢钠已收录):去剂型「片」后命中,不会再去剥成「碳酸氢」。
        assert_eq!(normalize("碳酸氢钠片").unwrap().key, "sodium_bicarbonate");
        // 候选式不破坏:词典没有的整体 miss,绝不误配(碳酸氢钙 → 碳酸氢 也配不上 → None)。
        assert!(normalize("碳酸氢钙片").is_none());
        // 剥壳只接受 Drug 类,不会把化验名误当药。
        assert_eq!(normalize("阿托伐他汀").unwrap().category, Category::Drug);
    }

    #[test]
    fn term_candidates_split_composite_names() {
        // 提取层拆分:整串必 miss,拆出的 token 命中。
        let hit = |name: &str| {
            term_candidates(name)
                .iter()
                .find_map(|c| normalize(c))
                .unwrap_or_else(|| panic!("no candidate hit for {name}"))
                .key
        };
        assert!(normalize("甘油三酯 TG").is_none(), "整串不该直配");
        assert_eq!(hit("甘油三酯 TG"), "triglycerides");
        assert_eq!(hit("肌酐 Cr(Scr)"), "creatinine");
        assert_eq!(hit("白细胞计数(WBC)"), "wbc");
        // 括号里才是能查到的那个(主体查不到时用括号内缩写)。
        assert_eq!(hit("糖化血红蛋白(HbA1c)"), "hba1c");
        // 拆不出任何已知 token → 老老实实 miss。
        assert!(term_candidates("完全不是术语 XYZ")
            .iter()
            .all(|c| normalize(c).is_none()));
    }

    #[test]
    fn strips_report_print_markers() {
        // 真实报告在项目名前印 #/*/★/☆/◆(重点关注/异常提示/院内惯例),剥完括号
        // 后 * 有时残留在尾部。这些都不是项目名的一部分。
        let hit = |name: &str| {
            term_candidates(name)
                .iter()
                .find_map(|c| normalize(c))
                .unwrap_or_else(|| panic!("no candidate hit for {name}"))
                .key
        };
        assert_eq!(hit("#白细胞计数"), "wbc");
        assert_eq!(hit("*红细胞计数"), "rbc");
        assert_eq!(hit("★血小板计数"), "plt");
        assert_eq!(hit("☆癌胚抗原"), "cea");
        assert_eq!(hit("◆乙肝e抗原"), "hbeag");
        // 剥括号后残留的尾部 *。
        assert_eq!(hit("γ-谷氨酰转肽酶(γ-GT化学法)*"), "ggt");
        // 叠加多个标记(前缀 ★ + *)。
        assert_eq!(hit("★*凝血酶原时间"), "pt");
        // 尾部 # 是别名本身的一部分(NEUT# = 绝对计数,≠ NEUT),不能被剥掉;
        // 整串本来就直配得到,不该被误剥成查不到的「NEUT」。
        assert_eq!(normalize("NEUT#").unwrap().key, "neut_count");
    }

    #[test]
    fn unit_notation_folds_but_never_folds_case() {
        // 记法差异(报告 vs UCUM)折叠后必须一致。
        for (report, ucum) in [
            ("×10^9/L", "10*9/L"),
            ("10^12/L", "10*12/L"),
            ("10E9/L", "10*9/L"),
            ("μmol/L", "umol/L"),
            ("µmol/L", "umol/L"),
            ("ｍｇ/ｄＬ", "mg/dL"),
            ("mg / L", "mg/L"),
            ("mL/min/1.73m²", "mL/min/1.73m2"),
        ] {
            assert_eq!(
                normalize_unit(report),
                normalize_unit(ucum),
                "{report} 应折叠到 {ucum}"
            );
        }
        // 大小写**不折**:mU/L(毫)≠ MU/L(兆),折了差 6 个数量级。
        assert_ne!(normalize_unit("mU/L"), normalize_unit("MU/L"));
        // 量纲不同的单位不会被记法折叠糊到一起(那是 units[] 换算的活)。
        assert_ne!(normalize_unit("mg/dL"), normalize_unit("mmol/L"));
    }

    #[test]
    fn matched_alias_is_the_dictionary_form() {
        // Query normalization must not leak into matched_alias: it reports the
        // dictionary's original alias, for traceability.
        let m = normalize("creatinine").unwrap();
        assert_eq!(m.matched_alias, "Creatinine");
    }

    #[test]
    fn drug_carries_ingredient_and_codes() {
        let m = normalize("格华止").unwrap();
        assert_eq!(m.key, "metformin");
        assert_eq!(m.category, Category::Drug);
        assert_eq!(m.ingredient.as_deref(), Some("Metformin"));
        assert_eq!(m.codes.rxnorm.as_deref(), Some("6809"));
        assert_eq!(m.codes.atc.as_deref(), Some("A10BA02"));
        assert_eq!(m.codes.omop_concept_id, Some(1503297));
        // drugs have no LOINC / canonical unit
        assert!(m.codes.loinc.is_none());
    }

    fn entry_for(key: &str) -> &'static Entry {
        dictionary_entries()
            .iter()
            .find(|e| e.key == key)
            .unwrap_or_else(|| panic!("missing entry {key}"))
    }

    #[test]
    fn creatinine_conversion_is_correct() {
        let e = entry_for("creatinine");
        assert_eq!(e.canonical_unit.as_deref(), Some("umol/L"));
        // canonical row is identity
        let canonical = e.units.iter().find(|u| u.unit == "umol/L").unwrap();
        assert_eq!(canonical.slope, 1.0);
        assert_eq!(canonical.intercept, 0.0);
        // mg/dL -> umol/L is the molar factor 88.42 (linear, intercept 0)
        let mgdl = e.units.iter().find(|u| u.unit == "mg/dL").unwrap();
        assert_eq!(mgdl.slope, 88.42);
        assert_eq!(mgdl.intercept, 0.0);
    }

    #[test]
    fn hba1c_conversion_is_affine_not_a_plain_factor() {
        let e = entry_for("hba1c");
        assert_eq!(e.canonical_unit.as_deref(), Some("%"));
        // IFCC mmol/mol -> NGSP %: NGSP% = 0.09148 * IFCC + 2.152 (AFFINE).
        // A plain factor (intercept 0) would be clinically wrong.
        let ifcc = e.units.iter().find(|u| u.unit == "mmol/mol").unwrap();
        assert_eq!(ifcc.slope, 0.09148);
        assert_eq!(ifcc.intercept, 2.152);
        assert!(
            ifcc.intercept != 0.0,
            "HbA1c IFCC->NGSP must be affine, not a plain factor"
        );
        // Spot-check the value: IFCC 53 mmol/mol ~= NGSP 7.0 %.
        let ngsp = ifcc.slope * 53.0 + ifcc.intercept;
        assert!((ngsp - 7.0).abs() < 0.05, "got {ngsp}");
    }

    #[test]
    fn completeness_all_required_items_present() {
        let keys: std::collections::HashSet<&str> = dictionary_entries()
            .iter()
            .map(|e| e.key.as_str())
            .collect();
        for req in REQUIRED_KEYS {
            assert!(keys.contains(req), "docs/015 §3.5 item missing: {req}");
        }
    }

    #[test]
    fn total_entry_count_is_expected() {
        // Coverage expansion (2026-07-14.1): 191 + 446 按专科批次扩容 = 637,再减 1
        // (2026-08-05:去重 polystyrene_sulfonate 的重复条目,见 dictionary_keys_are_globally_unique)= 636。
        // +4 (2026-08-13.1:MedRepBench 词典缺口扫描,补尿沉渣分析仪四项 ——
        // urine_pathologic_casts/urine_mucus/urine_yeast/urine_wbc_clumps,均有独立
        // LOINC 标准概念,见各条目 note)= 640。
        // A drift here means an entry was accidentally dropped or duplicated.
        assert_eq!(
            dictionary_entries().len(),
            640,
            "unexpected dictionary entry count"
        );
    }

    #[test]
    fn dictionary_keys_are_globally_unique() {
        // `key` 是查表/panel_for/problem_map ATC 匹配等一切下游逻辑的主键。重复 key
        // 本身不会让 parse 失败(entries 是数组,不是以 key 为键的 map),但会让归一化
        // 结果取决于 build_index 的遍历顺序——两条同 key 但内容不同的条目,谁的别名生效
        // 全看谁在数组里排在后面(HashMap::insert 后写覆盖先写),silently 不确定。
        // 曾经发生过(polystyrene_sulfonate 两条,别名列表还不完全一致),没有测试钉住才漏进来。
        let mut seen: HashMap<&str, usize> = HashMap::new();
        for (i, e) in dictionary_entries().iter().enumerate() {
            if let Some(&first) = seen.get(e.key.as_str()) {
                panic!(
                    "duplicate key {:?} at entries[{first}] and entries[{i}]",
                    e.key
                );
            }
            seen.insert(e.key.as_str(), i);
        }
    }

    #[test]
    fn system_never_set_on_drug_entries() {
        // `system`(标本类型)的文档明确写着「`None` for drugs」,但这个方向从没被断言过——
        // labs_and_vitals_have_canonical_unit_and_identity_row 只测了 canonical_unit/units,
        // 没人查过 system。跟 panel_never_set_on_drug_entries 是同一类盲点。
        for e in dictionary_entries() {
            if e.category == Category::Drug {
                assert!(
                    e.system.is_none(),
                    "{} is a drug but has a system: {:?}",
                    e.key,
                    e.system
                );
            }
        }
    }

    #[test]
    fn ingredient_never_set_on_lab_or_vital_entries() {
        // 反方向同理:`ingredient` 的文档写着「`Some` only for drugs」,但
        // labs_and_vitals_have_canonical_unit_and_identity_row 的 Lab/Vital 分支从没
        // 断言过 ingredient 恒为 None——只测了 Drug 分支必须 Some。
        for e in dictionary_entries() {
            if e.category != Category::Drug {
                assert!(
                    e.ingredient.is_none(),
                    "{} is category {:?} but has an ingredient: {:?}",
                    e.key,
                    e.category,
                    e.ingredient
                );
            }
        }
    }

    #[test]
    fn new_coverage_keys_resolve() {
        // Representative sample across the six new fragments (chemistry / heme /
        // endocrine-cardiac / urine-tumor-vitamin / vitals-drugs / drugs): each
        // must normalize() to the right key and category at full confidence.
        let cases: &[(&str, &str, Category)] = &[
            ("血钾", "potassium", Category::Lab),
            ("HCT", "hct", Category::Lab),
            ("FT3", "ft3", Category::Lab),
            ("CA125", "ca125", Category::Lab),
            ("尿蛋白", "urine_protein", Category::Lab),
            ("SpO2", "spo2", Category::Vital),
            ("替米沙坦", "telmisartan", Category::Drug),
            ("奥美拉唑", "omeprazole", Category::Drug),
        ];
        for (term, key, cat) in cases {
            let m = normalize(term).unwrap_or_else(|| panic!("no match for {term}"));
            assert_eq!(m.key, *key, "term {term}");
            assert_eq!(m.category, *cat, "term {term} category");
            assert_eq!(m.confidence, 1.0, "term {term} confidence");
        }
    }

    #[test]
    fn labs_and_vitals_have_canonical_unit_and_identity_row() {
        for e in dictionary_entries() {
            match e.category {
                // A lab/vital is either QUANTITATIVE (canonical_unit is Some) or
                // QUALITATIVE (canonical_unit is None, e.g. a urinalysis dipstick
                // ordinal like -/+/++). Both are valid; each has its own rule.
                Category::Lab | Category::Vital => match e.canonical_unit.as_deref() {
                    // Quantitative: there must be a units[] row for the canonical
                    // unit itself, and it must be the identity (slope 1, intercept 0).
                    Some(cu) => {
                        let row = e.units.iter().find(|u| u.unit == cu).unwrap_or_else(|| {
                            panic!("{} has no units row for canonical {cu}", e.key)
                        });
                        assert_eq!(row.slope, 1.0, "{} canonical row slope", e.key);
                        assert_eq!(row.intercept, 0.0, "{} canonical row intercept", e.key);
                    }
                    // Qualitative: no canonical unit means there is nothing to
                    // convert, so units[] MUST be empty — a conversion row here
                    // would be a bogus numeric mapping over an ordinal result.
                    None => {
                        assert!(
                            e.units.is_empty(),
                            "{} qualitative lab must have empty units (no bogus conversions)",
                            e.key
                        );
                    }
                },
                Category::Drug => {
                    // drugs carry no unit machinery, but must carry an ingredient
                    assert!(e.ingredient.is_some(), "{} drug missing ingredient", e.key);
                    assert!(
                        e.canonical_unit.is_none(),
                        "{} drug has canonical_unit",
                        e.key
                    );
                    assert!(e.units.is_empty(), "{} drug has units", e.key);
                }
            }
        }
    }

    #[test]
    fn loinc_property_agrees_with_canonical_unit() {
        // Design §5/§7: a lab's LOINC property/scale must not contradict its
        // canonical unit. Enforce the molar<->µmol/mmol and mass<->mg/g rule for
        // every entry whose canonical unit implies a substance-concentration
        // property, by asserting our deliberate molar-LOINC choices.
        let molar: &[(&str, &str, &str)] = &[
            ("creatinine", "14682-9", "umol/L"),
            ("urea", "22664-7", "mmol/L"),
            ("uric_acid", "14933-6", "umol/L"),
            ("glucose", "14749-6", "mmol/L"),
            ("cholesterol", "14647-2", "mmol/L"),
            ("ldl", "22748-8", "mmol/L"),
            ("hdl", "14646-4", "mmol/L"),
            ("triglycerides", "14927-8", "mmol/L"),
            ("tbil", "14631-6", "umol/L"),
            // New coverage — electrolytes, canonical molar mmol/L.
            ("potassium", "2823-3", "mmol/L"),
            ("sodium", "2951-2", "mmol/L"),
            ("chloride", "2075-0", "mmol/L"),
            ("calcium", "2000-8", "mmol/L"),
            ("phosphate", "14879-1", "mmol/L"),
            ("magnesium", "2601-3", "mmol/L"),
            ("bicarbonate", "1963-8", "mmol/L"),
            // Bilirubin fractions, canonical molar umol/L.
            ("direct_bilirubin", "14629-0", "umol/L"),
            ("indirect_bilirubin", "14630-8", "umol/L"),
            // Other clearly-molar analytes.
            ("homocysteine", "13965-9", "umol/L"),
            ("serum_iron", "14798-3", "umol/L"),
            // SI vitamins — mole-based canonicals (nmol/L, pmol/L).
            ("vitamin_d_25oh", "68438-1", "nmol/L"),
            ("vitamin_b12", "14685-2", "pmol/L"),
            ("folate", "14732-2", "nmol/L"),
        ];
        for (key, loinc, unit) in molar {
            let e = entry_for(key);
            assert_eq!(e.codes.loinc.as_deref(), Some(*loinc), "{key} loinc");
            assert_eq!(e.canonical_unit.as_deref(), Some(*unit), "{key} unit");
            // molar canonical must be a mole-based concentration
            assert!(
                unit.starts_with("pmol")
                    || unit.starts_with("nmol")
                    || unit.starts_with("umol")
                    || unit.starts_with("mmol"),
                "{key} canonical unit not molar"
            );
        }
    }

    #[test]
    fn no_duplicate_alias_within_category() {
        // Fail loudly rather than silently shadow: 同一类别内,一个归一别名不能被两个条目
        // 认领。跨类别同名是**允许的**(「叶酸」既是化验也是药),由 normalize/normalize_drug
        // 的两张表分流 —— 见 build_index。
        let mut seen: HashMap<(bool, String), String> = HashMap::new();
        for e in dictionary_entries() {
            let is_drug = e.category == Category::Drug;
            for a in e.aliases.iter().chain(e.ocr_confusions.iter()) {
                let k = (is_drug, normalize_term(a));
                if let Some(prev) = seen.get(&k) {
                    assert_eq!(
                        prev, &e.key,
                        "duplicate normalized alias {a:?} in entries {prev} and {}",
                        e.key
                    );
                }
                seen.insert(k, e.key.clone());
            }
        }
    }

    #[test]
    fn drug_namespace_wins_in_prescription_context() {
        // 「叶酸」在化验单上是化验项,在处方上是药 —— 两张表各查各的,谁也不抢谁。
        let lab = normalize("叶酸").expect("化验单语境");
        assert_eq!(lab.category, Category::Lab);
        let drug = normalize_drug("叶酸片 5mg")
            .or_else(|| {
                term_candidates("叶酸片 5mg")
                    .iter()
                    .find_map(|c| normalize_drug(c))
            })
            .expect("处方语境");
        assert_eq!(drug.category, Category::Drug);
        // 处方专表查不到的词照样 miss,不会退回化验项。
        assert!(normalize_drug("肌酐").is_none());
    }

    #[test]
    fn strips_injection_prefix_and_salt_suffix() {
        // 「注射用 + 通用名 + 成盐」:剥前缀与尾部成盐后命中通用名。
        assert_eq!(
            normalize_drug("注射用泮托拉唑钠").unwrap().key,
            "pantoprazole"
        );
        // 只剥剂型的候选必须先于「剥盐前缀」被试,否则「琥珀酸亚铁」会被剥成「亚铁」而丢掉。
        assert_eq!(
            normalize_drug("琥珀酸亚铁片").unwrap().canonical_name,
            "琥珀酸亚铁"
        );
    }

    #[test]
    fn panel_for_known_and_unknown_keys() {
        // 常见项各归其类(印刷惯例,见 panel_methodology.md)。
        assert_eq!(panel_for("creatinine"), Some("肾功能"));
        assert_eq!(panel_for("alt"), Some("肝功能"));
        assert_eq!(panel_for("wbc"), Some("血常规"));
        assert_eq!(panel_for("hgb"), Some("血常规"));
        assert_eq!(panel_for("plt"), Some("血常规"));
        // 血红蛋白只给一个 panel(血常规),即使它在 problem_map.json 里同时挂在
        // 「贫血相关」「肾功能」两条疾病泳道下 —— panel 是印刷分组,不是关注方向,
        // 两个维度不该互相渗透。
        // 不存在的 key、以及词典里确实没配 panel 的条目,都老实返回 None。
        assert_eq!(panel_for("完全不是术语"), None);
        assert_eq!(
            panel_for("cortisol"),
            None,
            "皮质醇节律没有稳定印刷惯例,留空"
        );
    }

    #[test]
    fn panel_catalog_matches_dictionary_distinct_panels() {
        // PANEL_CATALOG 是人工维护的展示顺序;这里钉住它与词典里实际出现的 panel
        // 值**完全一致**(不多不少) —— 漏了会让某个大类的 chip 永远不出现在目录
        // 里(即使有条目落在它下面),多了会在目录里挂一个查无条目的空 chip。
        let mut from_dict: Vec<&str> = dictionary_entries()
            .iter()
            .filter_map(|e| e.panel.as_deref())
            .collect();
        from_dict.sort_unstable();
        from_dict.dedup();
        let mut from_catalog: Vec<&str> = PANEL_CATALOG.to_vec();
        from_catalog.sort_unstable();
        assert_eq!(
            from_dict, from_catalog,
            "PANEL_CATALOG 与 dictionary.json 里实际出现的 panel 集合不一致"
        );
    }

    #[test]
    fn panel_never_set_on_drug_entries() {
        // panel 回答的是「这一项在报告单/病历上印在哪一栏下」。化验有(项目组表头),
        // 生命体征与体格测量也有(病历首页的固定栏位) —— **药没有**,它的分类维度是
        // ATC,不是报告单版式,给它 panel 只会在趋势页挂出一个查无实据的 chip。
        //
        // 这条原本写的是「只有 lab 能有 panel」。手动录入上线后,自测的血压/心率/
        // 体重全是 `Category::Vital`,而它们**必须**能被趋势页的分类入口选中 ——
        // 否则用户自己天天填的东西反而只能从「其他」里翻。放宽到 lab + vital,
        // 但对药继续钉死。
        for e in dictionary_entries() {
            if e.category == Category::Drug {
                assert!(
                    e.panel.is_none(),
                    "{} is a drug but has a panel: {:?}",
                    e.key,
                    e.panel
                );
            }
        }
    }

    #[test]
    fn every_self_measurable_vital_has_a_panel() {
        // 手动录入支持的五项(见 parser::self_entry)必须都能被分类入口选中。
        // 少一项就意味着那一项只能从「其他」里翻 —— 而「其他」是给未归一化的
        // 残留项准备的兜底,不是给产品主推功能的默认归宿。
        for key in [
            "bp_systolic",
            "bp_diastolic",
            "heart_rate",
            "body_temperature",
            "body_weight",
        ] {
            assert!(
                panel_for(key).is_some(),
                "{key} 是手动录入支持项,却没有 panel —— 它会掉进「其他」"
            );
        }
    }

    #[test]
    fn drugs_without_atc_are_all_explained() {
        // WORKLIST #9:53 条药物没有 ATC —— problem_map.json 按 ATC 前缀挂疾病泳道,
        // 没有 ATC 的药永远挂不到任何泳道。这些不是遗漏统计,是逐条查过 OMOP 本地
        // vocab(LOINC/RxNorm/ATC)后诚实记录的结论,理由分别写在各自的 `note` 里,
        // 汇总清单见 `atc_gaps_methodology.md`。
        //
        // 这条测试钉两件事:①数量不能悄悄涨——涨了要么是新条目忘了查 ATC,要么是
        // 方法学文档没跟上,两种都要求人去看一眼,而不是被下一次「补全字典」的批量
        // 提交悄悄吞掉;②每一条都必须有 `note` 解释留空理由——不允许「没查」和
        // 「查过确认没有」混在同一个空值里分不清。
        let no_atc: Vec<&Entry> = dictionary_entries()
            .iter()
            .filter(|e| e.category == Category::Drug && e.codes.atc.is_none())
            .collect();
        for e in &no_atc {
            assert!(
                e.note.is_some(),
                "{} 没有 ATC 也没有 note 解释原因 —— 补 note 或补 ATC,见 atc_gaps_methodology.md",
                e.key
            );
        }
        assert_eq!(
            no_atc.len(),
            53,
            "无 ATC 的 drug 条目数变了 —— 同步更新 atc_gaps_methodology.md 与这个数字"
        );
    }
}
