//! 第一层中文化的覆盖率计数(2026-10-23 spec §2.1.2):诊断 ICD → 中文名命中到哪一级、
//! 用药 RxNorm / 名字命中词典没有、化验 LOINC / 名字命中没有、标题映射得上没有。
//!
//! **只有计数与码**:输出里不出现任何值、日期、人名、原文;未命中的 LOINC / RxNorm 码与
//! 英文标题(Epic 小节名)列出来,是给补词典用的清单。用户在自己机器上对真实包跑
//! `medme --vault <dir> zh-coverage`,把这段文本贴回来即可。

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

/// 一个保险箱的第一层中文化覆盖率。全是计数与码;见模块文档。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ZhCoverage {
    pub docs: usize,
    pub docs_by_type: BTreeMap<String, usize>,
    pub docs_with_extraction: usize,
    /// 标题:`display_title_zh` 映射得上 / 本来就是中文 / 英文但认不出(去重列出,Epic 小节名)。
    pub titles_mapped: usize,
    pub titles_already_zh: usize,
    pub titles_unmapped: BTreeSet<String>,
    /// 诊断:四位亚目命中 / 只到类目 / 有码但表里没有(码列出)/ 没码。
    pub dx_sub4: usize,
    pub dx_cat3: usize,
    pub dx_none: usize,
    pub dx_uncoded: usize,
    pub dx_none_codes: BTreeSet<String>,
    /// 用药:RxNorm 命中词典 / 码没有或没命中但名字命中 / 都没有;词典里没有的 RxNorm 码列出。
    pub med_rxnorm_hit: usize,
    pub med_name_hit: usize,
    pub med_none: usize,
    pub med_miss_rxnorm: BTreeSet<String>,
    /// 化验:LOINC 命中 / 名字命中 / 原样透传;词典里没有的 LOINC 码列出。
    pub lab_loinc_hit: usize,
    pub lab_name_hit: usize,
    pub lab_passthrough: usize,
    pub lab_miss_loinc: BTreeSet<String>,
}

fn has_cjk(s: &str) -> bool {
    s.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c))
}

/// 每份文档一个三元组:`(doc_type, title, extraction_json)`。抽取 JSON 解析不出来的当作没有。
pub fn tally<'a>(
    docs: impl IntoIterator<Item = (&'a str, Option<&'a str>, Option<&'a str>)>,
) -> ZhCoverage {
    let mut c = ZhCoverage::default();
    for (doc_type, title, json) in docs {
        c.docs += 1;
        *c.docs_by_type.entry(doc_type.to_string()).or_default() += 1;
        if let Some(t) = title.map(str::trim).filter(|t| !t.is_empty()) {
            if has_cjk(t) {
                c.titles_already_zh += 1;
            } else if crate::display_title_zh(t).is_some() {
                c.titles_mapped += 1;
            } else {
                c.titles_unmapped.insert(t.to_string());
            }
        }
        let Some(e) = json.and_then(|j| deid::parse_extraction(j).ok()) else {
            continue;
        };
        c.docs_with_extraction += 1;
        for d in &e.diagnoses {
            let code = d.icd.trim();
            if code.is_empty() {
                c.dx_uncoded += 1;
                continue;
            }
            match terminology::resolve_icd10_zh(code).map(|m| m.level) {
                Some(terminology::IcdLevel::Sub4) => c.dx_sub4 += 1,
                Some(terminology::IcdLevel::Cat3) => c.dx_cat3 += 1,
                None => {
                    c.dx_none += 1;
                    c.dx_none_codes.insert(code.to_string());
                }
            }
        }
        for m in &e.meds {
            let code = m.rxnorm.trim();
            if !code.is_empty() && terminology::resolve_rxnorm(code).is_some() {
                c.med_rxnorm_hit += 1;
                continue;
            }
            if !code.is_empty() {
                c.med_miss_rxnorm.insert(code.to_string());
            }
            if terminology::resolve_drug(&m.name).is_some() {
                c.med_name_hit += 1;
            } else {
                c.med_none += 1;
            }
        }
        for l in &e.labs {
            let code = l.loinc.trim();
            if !code.is_empty() && terminology::resolve_loinc(code).is_some() {
                c.lab_loinc_hit += 1;
                continue;
            }
            if !code.is_empty() {
                c.lab_miss_loinc.insert(code.to_string());
            }
            let unit = Some(l.unit.as_str()).filter(|u| !u.trim().is_empty());
            if terminology::resolve(&l.name, unit).is_some() {
                c.lab_name_hit += 1;
            } else {
                c.lab_passthrough += 1;
            }
        }
    }
    c
}

impl fmt::Display for ZhCoverage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(
            f,
            "docs {}  with_extraction {}",
            self.docs, self.docs_with_extraction
        )?;
        for (t, n) in &self.docs_by_type {
            writeln!(f, "  type {t}: {n}")?;
        }
        writeln!(
            f,
            "titles  mapped {}  already_zh {}  unmapped {}",
            self.titles_mapped,
            self.titles_already_zh,
            self.titles_unmapped.len()
        )?;
        for t in &self.titles_unmapped {
            writeln!(f, "  unmapped title: {t}")?;
        }
        writeln!(
            f,
            "dx      sub4 {}  cat3 {}  none {}  uncoded {}",
            self.dx_sub4, self.dx_cat3, self.dx_none, self.dx_uncoded
        )?;
        for code in &self.dx_none_codes {
            writeln!(f, "  icd not in table: {code}")?;
        }
        writeln!(
            f,
            "meds    rxnorm_hit {}  name_hit {}  none {}",
            self.med_rxnorm_hit, self.med_name_hit, self.med_none
        )?;
        for code in &self.med_miss_rxnorm {
            writeln!(f, "  rxnorm not in dictionary: {code}")?;
        }
        writeln!(
            f,
            "labs    loinc_hit {}  name_hit {}  passthrough {}",
            self.lab_loinc_hit, self.lab_name_hit, self.lab_passthrough
        )?;
        for code in &self.lab_miss_loinc {
            writeln!(f, "  loinc not in dictionary: {code}")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DISCHARGE: &str =
        include_str!("../../profile/testdata/corpus-jane/2024-03-10_出院记录_UF.json");
    const VISIT: &str =
        include_str!("../../profile/testdata/corpus-jane/2025-11-17_门诊病历_UF.json");
    /// 专走「没命中」的几条路:表外 ICD、词典外 RxNorm、词典外 LOINC + 认不出的名字。
    const EXTRA: &str = r#"{"diagnoses":[{"text":"Long term use of anticoagulants","icd":"Z79.01"}],
        "meds":[{"name":"Fooxyzine","dose":"","freq":"","route":"","rxnorm":"9999999"}],
        "labs":[{"name":"Weirdase","value":"1","unit":"U/L","ref_low":"","ref_high":"","flag":"","loinc":"99999-9"}]}"#;

    #[test]
    fn tally_counts_levels_and_lists_misses() {
        let c = tally([
            (
                "discharge_summary",
                Some("Discharge Summary Note"),
                Some(DISCHARGE),
            ),
            (
                "clinical_note",
                Some("Office Visit Cardiology"),
                Some(VISIT),
            ),
            ("pathology", Some("SURGICAL PATHOLOGY"), Some(EXTRA)),
            ("lab_report", Some("化验 2025-08-18"), None),
        ]);
        assert_eq!(c.docs, 4);
        assert_eq!(c.docs_by_type["lab_report"], 1);
        assert_eq!(c.docs_with_extraction, 3);

        assert_eq!((c.titles_mapped, c.titles_already_zh), (2, 1));
        assert_eq!(
            c.titles_unmapped.iter().collect::<Vec<_>>(),
            ["SURGICAL PATHOLOGY"]
        );

        assert_eq!(
            (c.dx_sub4, c.dx_cat3, c.dx_none, c.dx_uncoded),
            (3, 0, 1, 1)
        );
        assert_eq!(c.dx_none_codes.iter().collect::<Vec<_>>(), ["Z79.01"]);

        assert_eq!((c.med_rxnorm_hit, c.med_name_hit, c.med_none), (5, 0, 1));
        assert_eq!(c.med_miss_rxnorm.iter().collect::<Vec<_>>(), ["9999999"]);

        // INR 6301-6、BNP 30934-4、CRP 1988-5 命中码;Creatinine 2160-0 与 Weirdase 99999-9 码落空,
        // 前者名字命中、后者透传;Galactomannan 没码、名字命中。
        assert_eq!(
            (c.lab_loinc_hit, c.lab_name_hit, c.lab_passthrough),
            (3, 2, 1)
        );
        assert_eq!(
            c.lab_miss_loinc.iter().collect::<Vec<_>>(),
            ["2160-0", "99999-9"]
        );

        let text = c.to_string();
        assert!(
            text.contains("Z79.01")
                && text.contains("2160-0")
                && text.contains("SURGICAL PATHOLOGY")
        );
        assert!(!text.contains("Doe"), "输出里不该有任何原文/人名");
    }

    #[test]
    fn tally_of_nothing_is_all_zero_and_prints() {
        let c = tally(Vec::<(&str, Option<&str>, Option<&str>)>::new());
        assert_eq!(c.docs, 0);
        assert!(c.to_string().contains("docs 0"));
    }
}
