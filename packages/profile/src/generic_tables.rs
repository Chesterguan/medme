//! 通用病程档案层的三张 const 表(2026-10-22 spec §3.1–§3.3):ICD-10 → 族、ATC 前缀 → 族、
//! 化验 key → 族。**分组,不是临床断言**:不产生任何新数值;不下发、不签名,改它就是发版。
//! 三张表发布前经只读 subagent 逐条核到码表,结论在 `docs/log/2026-10-22-generic-chronic-profile.md`。

/// 族 key 与中文标签,**固定顺序**(排序并列时按这个顺序;`other` 固定倒数第二、
/// `uncoded` 最后由调用方保证)。
pub(crate) const FAMILIES: &[(&str, &str)] = &[
    ("cardio", "心血管"),
    ("infection", "感染"),
    ("respiratory", "呼吸"),
    ("renal", "肾"),
    ("endocrine", "内分泌"),
    ("immune", "免疫"),
    ("neuro", "神经"),
    ("digestive", "消化"),
    ("oncology", "肿瘤"),
    ("blood", "血液"),
    ("musculoskeletal", "骨骼肌肉"),
    ("other", "其他"),
    ("uncoded", "未归类"),
];

pub(crate) fn family_label(key: &str) -> &'static str {
    FAMILIES
        .iter()
        .find(|(k, _)| *k == key)
        .map_or("其他", |(_, l)| l)
}

/// 族在 [`FAMILIES`] 里的序号(并列排序用);认不出的排最后。
pub(crate) fn family_rank(key: &str) -> usize {
    FAMILIES
        .iter()
        .position(|(k, _)| *k == key)
        .unwrap_or(FAMILIES.len())
}

/// 覆盖表(spec §3.1):`(前缀, 主族, 第二族)`,按**最长前缀**命中;一行只出现一次。
const ICD_OVERRIDES: &[(&str, &str, Option<&str>)] = &[
    ("Z95", "cardio", None),    // 心脏装置/人工瓣膜,章节 Z 本来进 other
    ("Z79.01", "cardio", None), // 长期抗凝;其余 Z79 留在 other(§9 第 4 条)
    ("Q20", "cardio", None),    // 先天性心脏 Q20–Q28
    ("Q21", "cardio", None),
    ("Q22", "cardio", None),
    ("Q23", "cardio", None),
    ("Q24", "cardio", None),
    ("Q25", "cardio", None),
    ("Q26", "cardio", None),
    ("Q27", "cardio", None),
    ("Q28", "cardio", None),
    ("I33", "cardio", Some("infection")),      // 感染性心内膜炎
    ("J12", "infection", Some("respiratory")), // 肺炎 J12–J18(病毒/肺炎链球菌/流感嗜血杆菌/其它)
    ("J13", "infection", Some("respiratory")),
    ("J14", "infection", Some("respiratory")),
    ("J15", "infection", Some("respiratory")),
    ("J16", "infection", Some("respiratory")),
    ("J17", "infection", Some("respiratory")),
    ("J18", "infection", Some("respiratory")),
    ("N39.0", "infection", Some("renal")),     // 尿路感染
    ("T81.4", "infection", None),              // 术后感染
    ("B44", "infection", Some("respiratory")), // 曲霉病(含 B44.1 肺曲霉病)
    ("N17", "renal", None),                    // 肾衰/CKD(已在章节内,列出只为注释)
    ("N18", "renal", None),
    ("N19", "renal", None),
    ("E10.2", "renal", Some("endocrine")), // 糖尿病肾病
    ("E11.2", "renal", Some("endocrine")),
    ("M05", "immune", None), // RA
    ("M06", "immune", None),
    ("G35", "immune", Some("neuro")),     // MS
    ("G36.0", "immune", Some("neuro")),   // NMOSD
    ("G70", "immune", Some("neuro")),     // MG
    ("K50", "immune", Some("digestive")), // IBD
    ("K51", "immune", Some("digestive")),
    ("L40", "immune", None), // 银屑病
];

/// 码的归一(spec §3.1):大写、去空白;第 4 位不是 `.` 且长度 >3 时在第 3 位后补 `.`
/// (Epic 无点写法 `I350` → `I35.0`);不是 `[A-Z]\d\d` 开头 → `None`(当作无码)。
pub(crate) fn normalize_icd(raw: &str) -> Option<String> {
    let s: String = raw
        .chars()
        .filter(|c| !c.is_whitespace())
        .map(|c| c.to_ascii_uppercase())
        .collect();
    let b = s.as_bytes();
    if b.len() < 3 || !b[0].is_ascii_uppercase() || !b[1].is_ascii_digit() || !b[2].is_ascii_digit()
    {
        return None;
    }
    if b.len() > 3 && b[3] != b'.' {
        return Some(format!("{}.{}", &s[..3], &s[3..]));
    }
    Some(s)
}

/// 归族(spec §3.1):覆盖表最长前缀 → 章节表(只有主族)。输入必须已经 [`normalize_icd`]。
pub(crate) fn family_of_icd(code: &str) -> (&'static str, Option<&'static str>) {
    if let Some((_, p, s)) = ICD_OVERRIDES
        .iter()
        .filter(|(prefix, _, _)| code.starts_with(prefix))
        .max_by_key(|(prefix, _, _)| prefix.len())
    {
        return (p, *s);
    }
    let Some(letter) = code.chars().next() else {
        return ("other", None);
    };
    let Ok(n) = code[1..3].parse::<u8>() else {
        return ("other", None);
    };
    let fam = match (letter, n) {
        ('A', _) | ('B', _) => "infection",
        ('C', _) | ('D', 0..=48) => "oncology",
        ('D', 50..=77) => "blood",
        ('D', 80..=89) => "immune",
        ('E', 0..=90) => "endocrine",
        ('G', _) => "neuro",
        ('I', _) => "cardio",
        ('J', _) => "respiratory",
        ('K', 0..=93) => "digestive",
        ('M', 30..=36) => "immune",
        ('M', _) => "musculoskeletal",
        ('N', 0..=39) => "renal",
        _ => "other",
    };
    (fam, None)
}

/// ATC 前缀 → 族(spec §3.2),第二项是小标(`J02` → 抗真菌)。只用于首屏计数与折叠。
const ATC_PREFIXES: &[(&str, &str, Option<&str>)] = &[
    ("B01", "cardio", None),
    ("C", "cardio", None),
    ("J01", "infection", None),
    ("J02", "infection", Some("抗真菌")),
    ("J04", "infection", None),
    ("J05", "infection", None),
    ("R", "respiratory", None),
    ("A10", "endocrine", None),
    ("H03", "endocrine", None),
    ("H02", "immune", None),
    ("L04", "immune", None),
    ("N03", "neuro", None),
    ("N04", "neuro", None),
    ("N07", "neuro", None),
    ("L01", "oncology", None),
    ("L02", "oncology", None), // 内分泌治疗(他莫昔芬、阿那曲唑)也是肿瘤用药(核查补)
                               // N02 止痛、N05/N06 精神类 → other,不往「神经」里扫。
];

pub(crate) fn family_of_atc(atc: Option<&str>) -> (&'static str, Option<&'static str>) {
    let Some(atc) = atc.map(str::trim).filter(|a| !a.is_empty()) else {
        return ("other", None);
    };
    ATC_PREFIXES
        .iter()
        .filter(|(p, _, _)| atc.starts_with(p))
        .max_by_key(|(p, _, _)| p.len())
        .map_or(("other", None), |(_, f, n)| (f, *n))
}

/// 化验 key 覆盖表(spec §3.3):族 → 词典 key。同一个 key 可以出现在多个族,序列只有一份,
/// 表只是指针。词典里没有的 key 不许进来(`lab_keys_exist_in_dictionary` 守着)。
pub(crate) const LAB_KEYS: &[(&str, &[&str])] = &[
    (
        "cardio",
        &[
            "bnp",
            "nt_probnp",
            "troponin_i",
            "troponin_t",
            "hs_troponin_i",
            "hs_troponin_t",
            "inr",
            "pt",
            "creatinine",
            "potassium",
            "ldl",
            "hba1c",
            "digoxin_level",
        ],
    ),
    (
        "infection",
        &[
            "crp",
            "hscrp",
            "esr",
            "wbc",
            "il6",
            "lactate",
            "pct",
            "galactomannan",
            "beta_d_glucan",
            "voriconazole_level",
        ],
    ),
    (
        "renal",
        &[
            "creatinine",
            "egfr",
            "urine_acr",
            "urine_pcr",
            "uric_acid",
            "phosphate",
            "pth",
        ],
    ),
    (
        "endocrine",
        &[
            "hba1c",
            "glucose",
            "tsh",
            "ldl",
            "hdl",
            "triglycerides",
            "vitamin_d_25oh",
        ],
    ),
    ("immune", &["crp", "esr", "ferritin", "tacrolimus_level"]),
];

/// 词典 `panel` → 族的兜底(spec §3.3 第 1 条);`common` = 每族首屏都看得到的一小排。
pub(crate) const PANEL_FAMILY: &[(&str, &str)] = &[
    ("心肌标志物", "cardio"),
    ("凝血", "cardio"),
    ("肾功能", "renal"),
    ("血糖", "endocrine"),
    ("甲状腺功能", "endocrine"),
    ("血脂", "endocrine"),
    ("炎症/感染", "infection"),
    ("风湿免疫", "immune"),
    ("血常规", "common"),
    ("电解质", "common"),
    ("肝功能", "common"),
    ("尿液", "common"),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_icd_handles_epic_and_cn_spellings() {
        assert_eq!(normalize_icd("I350").as_deref(), Some("I35.0"));
        assert_eq!(normalize_icd(" i35.0 ").as_deref(), Some("I35.0"));
        assert_eq!(normalize_icd("I10.x00").as_deref(), Some("I10.X00"));
        assert_eq!(normalize_icd("Z95.2").as_deref(), Some("Z95.2"));
        assert_eq!(normalize_icd("E11").as_deref(), Some("E11"));
        assert_eq!(normalize_icd("abc"), None);
        assert_eq!(normalize_icd(""), None);
        assert_eq!(normalize_icd("1234"), None);
    }

    #[test]
    fn family_of_icd_override_table_beats_chapter() {
        assert_eq!(family_of_icd("Z95.2"), ("cardio", None));
        assert_eq!(family_of_icd("I33.0"), ("cardio", Some("infection")));
        assert_eq!(family_of_icd("B44.1"), ("infection", Some("respiratory")));
        assert_eq!(family_of_icd("N39.0"), ("infection", Some("renal")));
        assert_eq!(family_of_icd("E11.21"), ("renal", Some("endocrine")));
        assert_eq!(family_of_icd("E11.9"), ("endocrine", None));
        assert_eq!(family_of_icd("Z79.01"), ("cardio", None));
        assert_eq!(family_of_icd("Z79.4"), ("other", None));
        assert_eq!(family_of_icd("G35"), ("immune", Some("neuro")));
        assert_eq!(family_of_icd("K50.9"), ("immune", Some("digestive")));
        assert_eq!(family_of_icd("Q21.0"), ("cardio", None));
        assert_eq!(family_of_icd("T81.4"), ("infection", None));
        assert_eq!(family_of_icd("J13"), ("infection", Some("respiratory")));
    }

    #[test]
    fn family_of_icd_chapter_table() {
        assert_eq!(family_of_icd("M32.1"), ("immune", None));
        assert_eq!(family_of_icd("M17.0"), ("musculoskeletal", None));
        assert_eq!(family_of_icd("N40"), ("other", None));
        assert_eq!(family_of_icd("N18.3"), ("renal", None));
        assert_eq!(family_of_icd("C34.1"), ("oncology", None));
        assert_eq!(family_of_icd("D50.9"), ("blood", None));
        assert_eq!(family_of_icd("D84.9"), ("immune", None));
        assert_eq!(family_of_icd("A41.9"), ("infection", None));
        assert_eq!(family_of_icd("I10"), ("cardio", None));
        assert_eq!(family_of_icd("J44.1"), ("respiratory", None));
        assert_eq!(family_of_icd("K21.0"), ("digestive", None));
        assert_eq!(family_of_icd("E03.9"), ("endocrine", None));
        assert_eq!(family_of_icd("G40.9"), ("neuro", None));
        assert_eq!(family_of_icd("F32.9"), ("other", None));
        assert_eq!(family_of_icd("S72.0"), ("other", None));
    }

    #[test]
    fn family_of_atc_prefixes() {
        assert_eq!(
            family_of_atc(Some("J02AC03")),
            ("infection", Some("抗真菌"))
        );
        assert_eq!(family_of_atc(Some("B01AA03")), ("cardio", None));
        assert_eq!(family_of_atc(Some("C07AB02")), ("cardio", None));
        assert_eq!(family_of_atc(Some("J01CA04")), ("infection", None));
        assert_eq!(family_of_atc(Some("H02AB07")), ("immune", None));
        assert_eq!(family_of_atc(Some("L04AD02")), ("immune", None));
        assert_eq!(family_of_atc(Some("A10BA02")), ("endocrine", None));
        assert_eq!(family_of_atc(Some("N03AX")), ("neuro", None));
        assert_eq!(family_of_atc(Some("N02BE01")), ("other", None));
        assert_eq!(family_of_atc(Some("N05AH")), ("other", None));
        assert_eq!(family_of_atc(Some("L01XC")), ("oncology", None));
        assert_eq!(family_of_atc(Some("L02BA01")), ("oncology", None));
        assert_eq!(family_of_atc(Some("R03AC")), ("respiratory", None));
        assert_eq!(family_of_atc(None), ("other", None));
    }

    /// 小表里的每个 key 都得真在词典里 —— 词典改名这里立刻红,不会静默少一行。
    #[test]
    fn lab_keys_exist_in_dictionary() {
        for (family, keys) in LAB_KEYS {
            assert!(FAMILIES.iter().any(|(k, _)| k == family), "未知族 {family}");
            for k in *keys {
                assert!(
                    terminology::dictionary_entries()
                        .iter()
                        .any(|e| &e.key == k),
                    "词典里没有 {k}({family})"
                );
            }
        }
        for (panel, family) in PANEL_FAMILY {
            assert!(
                terminology::PANEL_CATALOG.contains(panel),
                "词典没有大类 {panel}"
            );
            assert!(
                *family == "common" || FAMILIES.iter().any(|(k, _)| k == family),
                "未知族 {family}"
            );
        }
        assert!(family_label("cardio") == "心血管" && family_label("uncoded") == "未归类");
    }
}
